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
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/libp2p/go-yamux/v5"
)

// Plain SSH (= no container) の broker が listen してる loopback ポート。
// router 自身は :19222 を取るので、ローカル broker は別ポートで起動する。
const routerLocalBrokerPort = 19223

type routePreamble struct {
	ProjShort string `json:"projShort"`
	Kind      string `json:"kind"` // "pty" | "control"
}

// Container 情報。.env から読み込む。
type projInfo struct {
	CID string // container id
	RWS string // remote workspace path inside container
	CIP string // container IP
}

// 修復中の CID を追跡。同じ container への重複修復を避ける。
// + 直近 repair 完了時刻も覚えておく — 連続で来た repair 要求を thrash させない
// (16 pane が同時 reconnect すると pane ごとに repair 発火 → kill ループ)。
var (
	repairMu         sync.Mutex
	repairInProgress = map[string]bool{}
	repairLastDone   = map[string]time.Time{}
)

const repairCooldown = 8 * time.Second

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

// muxYamuxConfig: Belve のユースケース (claude TUI + MCP の重い burst, replay
// buffer 4 MiB) に合わせたチューニング。詳細は
// docs/notes/2026-06-24-yamux-multiplex.md 参照。
func muxYamuxConfig() *yamux.Config {
	cfg := yamux.DefaultConfig()
	cfg.MaxStreamWindowSize = 16 << 20 // 16 MiB
	cfg.KeepAliveInterval = 30 * time.Second
	cfg.ConnectionWriteTimeout = 10 * time.Second
	cfg.AcceptBacklog = 256
	return cfg
}

// runMuxRouter: Mac mac-master からの yamux session を accept する。1 TCP =
// 1 yamux session = N streams で、各 stream が 1 pane / 1 control RPC に対応する。
// Stream は既存 router の preamble protocol をそのまま流す (= dispatchRouterStream
// 流用)。旧 runRouter (19200) と完全分離して走るので、新旧 path が同 process 内
// で共存できる (= 設定 mistake が silent に通らない)。
func runMuxRouter(listenAddr string) {
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] mux-router listen %s: %v\n", listenAddr, err)
		return
	}
	fmt.Fprintf(os.Stderr, "[belve-persist] mux-router listening on %s\n", listenAddr)
	for {
		client, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router accept: %v\n", err)
			continue
		}
		go handleMuxSession(client)
	}
}

func handleMuxSession(conn net.Conn) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router session panic: %v\n", r)
		}
	}()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
	}
	sess, err := yamux.Server(conn, muxYamuxConfig(), nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] yamux.Server: %v\n", err)
		conn.Close()
		return
	}
	defer sess.Close()
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router AcceptStream: %v\n", err)
			return
		}
		go handleMuxStream(stream)
	}
}

func handleMuxStream(stream *yamux.Stream) {
	defer stream.Close()
	muxTraceVM("stream-open id=%d", stream.StreamID())
	_ = stream.SetReadDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(stream)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] mux-router preamble read: %v\n", err)
		return
	}
	_ = stream.SetReadDeadline(time.Time{})

	pre, ok := parseAndValidatePreamble(line)
	if !ok {
		return
	}
	muxTraceVM("stream-route id=%d projShort=%q kind=%q", stream.StreamID(), pre.ProjShort, pre.Kind)
	dispatchRouterStream(stream, reader, pre)
	muxTraceVM("stream-close id=%d", stream.StreamID())
}

// muxTraceVM: BELVE_MUX_TRACE=1 の時だけ /tmp/belve-mux-vm.log に append。
// binary payload は記録しない (= 30 GB log 事故防止)。preamble / lifecycle のみ。
var (
	muxTraceMu   sync.Mutex
	muxTraceFile *os.File
	muxTraceInit sync.Once
)

func muxTraceVM(format string, args ...interface{}) {
	if os.Getenv("BELVE_MUX_TRACE") != "1" {
		return
	}
	muxTraceInit.Do(func() {
		f, err := os.OpenFile("/tmp/belve-mux-vm.log",
			os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err == nil {
			muxTraceFile = f
		}
	})
	muxTraceMu.Lock()
	defer muxTraceMu.Unlock()
	if muxTraceFile == nil {
		return
	}
	fmt.Fprintf(muxTraceFile, "%s "+format+"\n",
		append([]interface{}{time.Now().Format(time.RFC3339Nano)}, args...)...)
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

	pre, ok := parseAndValidatePreamble(line)
	if !ok {
		return
	}
	dispatchRouterStream(client, reader, pre)
}

// parseAndValidatePreamble: NDJSON preamble 1 行を読んで validate する。
// `handleRouterConn` (旧 path) と `handleMuxStream` (新 path) で共通。
func parseAndValidatePreamble(line []byte) (routePreamble, bool) {
	var pre routePreamble
	if err := json.Unmarshal(line, &pre); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router preamble parse err: %v line=%q\n", err, line)
		return pre, false
	}
	if pre.Kind != "pty" && pre.Kind != "control" {
		fmt.Fprintf(os.Stderr, "[belve-persist] router unknown kind: %q\n", pre.Kind)
		return pre, false
	}
	return pre, true
}

// dispatchRouterStream: preamble 解析済みの client (= raw TCP or yamux.Stream)
// を upstream broker に proxy する。preamble 後の buffered byte は upstream へ
// flush。bidir copy。
//
// `client` の SetNoDelay は TCPConn の時だけ有効。yamux.Stream は internal flow
// control を持つので NoDelay 操作不要。
func dispatchRouterStream(client net.Conn, reader *bufio.Reader, pre routePreamble) {
	target, err := resolveTarget(pre)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router resolve err: %v projShort=%q kind=%q\n", err, pre.ProjShort, pre.Kind)
		return
	}

	upstream, err := dialWithHealing(target, pre)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router dial %s: %v\n", target, err)
		return
	}
	defer upstream.Close()

	// PTY は 1 byte ずつ流れる事が多い (キーストローク)。Nagle が効くと
	// パケット集約で ~40-200ms の遅延が乗るので両方向で TCP_NODELAY を有効化。
	// yamux.Stream は対象外 (= 内部で flow control 済み)。
	if tc, ok := client.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	if tc, ok := upstream.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}

	// 双方向 piping。bufio に残ってる byte を先に upstream へ流す。
	go func() {
		// upstream → client
		_, _ = io.Copy(client, upstream)
		_ = client.SetReadDeadline(time.Now()) // pump 1 を解除 (TCPConn のみ効く)
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

// 通常の dial を試して、container broker が居なかったら docker exec で
// 復旧 (binary cp + 起動) してから再試行する。Mac クライアントは「RPC が
// 一時的に遅い」だけ感じる (= fallback storm が起きない)。
//
// Plain SSH (= projShort 空 or .env 無し) の場合、router が直接 broker を
// 起こす権限を持つので docker は触らず単に dial → ダメなら諦める。
func dialWithHealing(target string, pre routePreamble) (net.Conn, error) {
	// First try
	if conn, err := net.DialTimeout("tcp", target, 1500*time.Millisecond); err == nil {
		return conn, nil
	}
	// Container broker が居なければ docker exec で復旧。projShort 空なら
	// 復旧手段がないので諦め。
	if pre.ProjShort == "" {
		return nil, fmt.Errorf("dial %s failed (no recovery for plain ssh)", target)
	}
	info, err := readProjInfo(pre.ProjShort)
	if err != nil || info.CID == "" {
		return nil, fmt.Errorf("project info unavailable: %w", err)
	}
	if err := repairContainerBroker(info); err != nil {
		return nil, fmt.Errorf("repair: %w", err)
	}
	// 復旧後は broker が listening になるまで poll (~10s budget)。
	for i := 0; i < 50; i++ {
		time.Sleep(200 * time.Millisecond)
		if conn, err := net.DialTimeout("tcp", target, 800*time.Millisecond); err == nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] router healed cid=%s target=%s after=%dms\n",
				info.CID[:12], target, (i+1)*200)
			return conn, nil
		}
	}
	return nil, fmt.Errorf("broker did not become ready after repair")
}

// container 内に新 binary を入れ直して broker を再起動する。
// - 同じ CID への並行呼び出しは block (in-flight dedup)
// - 直近 repairCooldown 以内に成功してれば skip (connection 嵐対策)
func repairContainerBroker(info *projInfo) error {
	repairMu.Lock()
	if repairInProgress[info.CID] {
		repairMu.Unlock()
		for {
			time.Sleep(100 * time.Millisecond)
			repairMu.Lock()
			done := !repairInProgress[info.CID]
			repairMu.Unlock()
			if done {
				return nil
			}
		}
	}
	if last, ok := repairLastDone[info.CID]; ok && time.Since(last) < repairCooldown {
		// 直近で repair 完了済 — broker は最初の repair で復旧済のはず。
		// ここでまた kill+spawn すると thrash する。dial poll に任せる。
		repairMu.Unlock()
		return nil
	}
	repairInProgress[info.CID] = true
	repairMu.Unlock()
	defer func() {
		repairMu.Lock()
		delete(repairInProgress, info.CID)
		repairLastDone[info.CID] = time.Now()
		repairMu.Unlock()
	}()

	fmt.Fprintf(os.Stderr, "[belve-persist] router repairing cid=%s\n", info.CID[:12])
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	binSrc := filepath.Join(home, ".belve/bin/belve-persist")
	if _, err := os.Stat(binSrc); err != nil {
		return fmt.Errorf("VM-side binary missing: %w", err)
	}
	bootstrapSrc := filepath.Join(home, ".belve/session-bootstrap.sh")

	// 1) container 内に必要な dir を作る (失敗は無視 — 既にあるかも)
	_ = exec.Command("docker", "exec", info.CID, "mkdir", "-p", "/root/.belve/bin", "/root/.belve/sessions").Run()

	// 2) binary 配布
	if err := exec.Command("docker", "cp", binSrc, info.CID+":/root/.belve/bin/belve-persist").Run(); err != nil {
		return fmt.Errorf("docker cp belve-persist: %w", err)
	}
	if _, err := os.Stat(bootstrapSrc); err == nil {
		_ = exec.Command("docker", "cp", bootstrapSrc, info.CID+":/root/.belve/session-bootstrap.sh").Run()
	}
	_ = exec.Command("docker", "exec", info.CID, "chmod", "+x", "/root/.belve/bin/belve-persist", "/root/.belve/session-bootstrap.sh").Run()

	// 3) 旧 broker を kill (pkill 無いので /proc 経由で探して kill)
	_ = exec.Command("docker", "exec", info.CID, "sh", "-c",
		`for p in /proc/[0-9]*; do read cmd < $p/comm 2>/dev/null; [ "$cmd" = "belve-persist" ] && kill -9 $(basename $p); done`).Run()
	time.Sleep(200 * time.Millisecond)

	// 4) 新 broker 起動 (PTY + control 両方)
	wd := info.RWS
	if wd == "" {
		wd = "/"
	}
	if err := exec.Command("docker", "exec", "-d",
		"-e", "BELVE_SESSION=1", "-e", "TERM=xterm-256color", "-w", wd,
		info.CID, "sh", "-c",
		"/root/.belve/bin/belve-persist -tcplisten 0.0.0.0:19222 -controllisten 0.0.0.0:19224 -command /root/.belve/session-bootstrap.sh 2>>/root/.belve/broker.log",
	).Run(); err != nil {
		return fmt.Errorf("docker exec start broker: %w", err)
	}
	return nil
}

// .env を読んで CID/RWS/CIP を返す。CIP は resolveTarget も使うので、
// ここで読む方を将来統一してもよい (今は readContainerIP と重複)。
func readProjInfo(projShort string) (*projInfo, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	envPath := filepath.Join(home, ".belve", "projects", projShort+".env")
	f, err := os.Open(envPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	info := &projInfo{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		switch {
		case strings.HasPrefix(line, "CID="):
			info.CID = strings.TrimPrefix(line, "CID=")
		case strings.HasPrefix(line, "RWS="):
			info.RWS = strings.TrimPrefix(line, "RWS=")
		case strings.HasPrefix(line, "CIP="):
			info.CIP = strings.TrimPrefix(line, "CIP=")
		}
	}
	return info, nil
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
