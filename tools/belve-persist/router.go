package main

// VM-side router. Mac から SSH forward 1 本でここに到着する全接続を、
// preamble で指定された container broker に proxy する。
//
// Wire 仕様: 接続後、最初の 1 行に NDJSON でルーティング情報を送る。
//   {"projShort":"abc12345","kind":"pty"}    → CIP:19222 (PTY broker) へ
//   {"projShort":"abc12345","kind":"control"} → CIP:19224 (control RPC) へ
//
// preamble の後ろに本来のプロトコル (PTY なら msgSession、control なら NDJSON
// req) がそのまま続く。router は preamble を消費した後、buffered な残バイトを
// upstream に書き出してから `io.Copy` で双方向 piping する。
//
// CIP は `~/.belve/projects/<projShort>.env` の `CIP=...` 行から取得。
// .env が無ければ「Plain SSH project」とみなして 127.0.0.1 (VM loopback) に
// proxy する (この場合の broker は別ポート — `routerLocalBrokerPort`)。

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Plain SSH (= no container) の broker が listen してる loopback ポート。
// router 自身は :19222 を取るので、ローカル broker は別ポートで起動する。
const routerLocalBrokerPort = 19223

type routePreamble struct {
	ProjShort string `json:"projShort"`
	Kind      string `json:"kind"` // "pty" | "control"
}

func runRouter(listenAddr string) {
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router listen %s: %v\n", listenAddr, err)
		return
	}
	fmt.Fprintf(os.Stderr, "[belve-persist] router listening on %s\n", listenAddr)
	for {
		client, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] router accept: %v\n", err)
			continue
		}
		go func(c net.Conn) {
			defer func() {
				if r := recover(); r != nil {
					fmt.Fprintf(os.Stderr, "[belve-persist] router panic: %v\n", r)
				}
			}()
			handleRouterConn(c)
		}(client)
	}
}

func handleRouterConn(client net.Conn) {
	defer client.Close()
	// Preamble を 1 行読み取り。あまりに大きい preamble (= bug or attack) は
	// 弾く。本来は 100 byte 以内に収まる。
	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(client)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router preamble read err: %v\n", err)
		return
	}
	_ = client.SetReadDeadline(time.Time{}) // 解除

	var pre routePreamble
	if err := json.Unmarshal(line, &pre); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router preamble parse err: %v line=%q\n", err, line)
		return
	}
	if pre.Kind != "pty" && pre.Kind != "control" {
		fmt.Fprintf(os.Stderr, "[belve-persist] router unknown kind: %q\n", pre.Kind)
		return
	}

	target, err := resolveTarget(pre)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router resolve err: %v projShort=%q kind=%q\n", err, pre.ProjShort, pre.Kind)
		return
	}

	upstream, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router dial %s: %v\n", target, err)
		return
	}
	defer upstream.Close()

	// 双方向 piping。bufio に残ってる byte を先に upstream へ流す。
	// (読んだ preamble 行はもう消費済みなので、buffer 残り = preamble 後ろの
	// 本来のプロトコルバイト)
	go func() {
		// upstream → client
		_, _ = io.Copy(client, upstream)
		_ = client.SetReadDeadline(time.Now()) // pump 1 を解除
	}()
	if buffered := reader.Buffered(); buffered > 0 {
		head := make([]byte, buffered)
		_, _ = io.ReadFull(reader, head)
		if _, err := upstream.Write(head); err != nil {
			return
		}
	}
	// client → upstream
	_, _ = io.Copy(upstream, client)
}

// projShort に対応する container IP を解決して "<ip>:<port>" を返す。
// .env が無ければ Plain SSH とみなして loopback の VM-local broker に向ける。
func resolveTarget(pre routePreamble) (string, error) {
	port := 19222
	if pre.Kind == "control" {
		port = 19224
	}
	// Plain SSH: projShort 空 or .env 無し
	if pre.ProjShort == "" {
		return fmt.Sprintf("127.0.0.1:%d", localPortFor(pre.Kind)), nil
	}
	cip, err := readContainerIP(pre.ProjShort)
	if err != nil {
		// .env 読めないなら Plain SSH 扱いに fallback
		return fmt.Sprintf("127.0.0.1:%d", localPortFor(pre.Kind)), nil
	}
	return fmt.Sprintf("%s:%d", cip, port), nil
}

// Plain SSH 用の VM-local broker は 19222 (router) と被らないよう別ポート。
// PTY = 19223、control = 19225 にずらす。
func localPortFor(kind string) int {
	if kind == "control" {
		return 19225
	}
	return routerLocalBrokerPort
}

func readContainerIP(projShort string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	envPath := filepath.Join(home, ".belve", "projects", projShort+".env")
	f, err := os.Open(envPath)
	if err != nil {
		return "", err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "CIP=") {
			cip := strings.TrimSpace(strings.TrimPrefix(line, "CIP="))
			if cip != "" {
				return cip, nil
			}
		}
	}
	return "", fmt.Errorf("CIP not found in %s", envPath)
}
