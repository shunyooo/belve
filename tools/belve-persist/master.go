package main

// Mac master daemon. Belve.app から Unix socket で IPC を受け、project setup /
// tunnel / session 管理を一元化する。Phase 1 段階では ping/version op だけ持つ
// skeleton で、Belve.app から spawn + 疎通確認できる事を確認する用。
//
// 詳細設計: docs/notes/2026-04-23-mac-master-design.md
//
// Wire format: NDJSON (control.go と同じ形)。
//   req:  {"id":"1","op":"ping"}
//   res:  {"id":"1","ok":true,"result":{...}}

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
)

// Master が公開する API のバージョン。Belve.app は handshake でこの値を
// 確認し、想定と違ったら master を kill → spawn し直して新版に attach する
// (= broker の version negotiation 議論を Mac 側に持ってきた版)。
const macMasterVersion = "1.0"

type masterReq struct {
	ID     string                 `json:"id"`
	Op     string                 `json:"op"`
	Params map[string]interface{} `json:"params,omitempty"`
}

type masterRes struct {
	ID     string      `json:"id"`
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

type masterConn struct {
	conn  net.Conn
	enc   *json.Encoder
	encMu sync.Mutex
}

func (mc *masterConn) write(v interface{}) error {
	mc.encMu.Lock()
	defer mc.encMu.Unlock()
	return mc.enc.Encode(v)
}

func runMacMaster(socketPath string) {
	if socketPath == "" {
		fmt.Fprintln(os.Stderr, "[belve-master] -socket required")
		os.Exit(1)
	}
	// 既存の socket を消す (前回 instance が unclean shutdown した場合の残骸)。
	// 多重起動防止は Belve.app 側で「先に ping して応答あれば spawn しない」
	// という形で担保する設計なので、master 自身は単純に消す。
	_ = os.Remove(socketPath)

	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] mkdir %s: %v\n", filepath.Dir(socketPath), err)
		os.Exit(1)
	}

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] listen %s: %v\n", socketPath, err)
		os.Exit(1)
	}
	defer listener.Close()
	fmt.Fprintf(os.Stderr, "[belve-master] listening on %s (version=%s)\n", socketPath, macMasterVersion)

	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] accept: %v\n", err)
			continue
		}
		go handleMasterConn(&masterConn{conn: conn, enc: json.NewEncoder(conn)})
	}
}

func handleMasterConn(mc *masterConn) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] conn panic: %v\n", r)
		}
		mc.conn.Close()
	}()
	reader := bufio.NewReader(mc.conn)
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "[belve-master] read: %v\n", err)
			}
			return
		}
		var req masterReq
		if err := json.Unmarshal(line, &req); err != nil {
			_ = mc.write(masterRes{OK: false, Error: fmt.Sprintf("bad json: %v", err)})
			continue
		}
		res := safeMasterDispatch(req)
		if err := mc.write(res); err != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] write: %v\n", err)
			return
		}
	}
}

func safeMasterDispatch(req masterReq) (res masterRes) {
	defer func() {
		if r := recover(); r != nil {
			res = masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("handler panic: %v", r)}
		}
	}()
	return masterDispatch(req)
}

func masterDispatch(req masterReq) masterRes {
	switch req.Op {
	case "ping":
		return masterRes{ID: req.ID, OK: true, Result: map[string]string{"pong": "ok"}}
	case "version":
		return masterRes{ID: req.ID, OK: true, Result: map[string]string{
			"version": macMasterVersion,
			"pid":     fmt.Sprintf("%d", os.Getpid()),
		}}
	case "ensureSetup":
		return opEnsureSetup(req)
	case "invalidateSetup":
		return opInvalidateSetup(req)
	case "ensureControlMaster":
		return opEnsureControlMaster(req)
	case "ensureRouterForward":
		return opEnsureRouterForward(req)
	case "tunnelStatus":
		return opTunnelStatus(req)
	case "teardownAllTunnels":
		return opTeardownAllTunnels(req)
	default:
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("unknown op: %s", req.Op)}
	}
}

// ensureSetup params: {projectId, host, isDevContainer, workspacePath, projShort, binDir}
// 戻り値: {state: "ready"|"failed", error?: "..."}
func opEnsureSetup(req masterReq) masterRes {
	p := req.Params
	sreq := setupReq{
		ProjectID:      strParam(p, "projectId"),
		Host:           strParam(p, "host"),
		IsDevContainer: boolParam(p, "isDevContainer"),
		WorkspacePath:  strParam(p, "workspacePath"),
		ProjShort:      strParam(p, "projShort"),
		BinDir:         strParam(p, "binDir"),
	}
	st, errStr := globalSetupManager.ensureSetup(sreq)
	result := map[string]string{"state": st.String()}
	if errStr != "" {
		result["error"] = errStr
	}
	return masterRes{ID: req.ID, OK: st == setupReady, Result: result, Error: errStr}
}

// invalidateSetup: 指定 project の setup state をリセット (= 次回 ensureSetup で再実行)。
// container 再構築 / broker 死亡時に Belve.app から呼ぶ。
func opInvalidateSetup(req masterReq) masterRes {
	pid := strParam(req.Params, "projectId")
	if pid == "" {
		return masterRes{ID: req.ID, OK: false, Error: "projectId required"}
	}
	globalSetupManager.invalidate(pid)
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"projectId": pid}}
}

// ensureControlMaster params: {host}
// SSH master を spawn (なければ)。port forward を伴わない用途 (= PortForwardManager
// が独自に `ssh -O forward` する前) で使う。
func opEnsureControlMaster(req masterReq) masterRes {
	host := strParam(req.Params, "host")
	if host == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host required"}
	}
	if err := globalTunnelManager.ensureControlMaster(host); err != nil {
		return masterRes{ID: req.ID, OK: false, Error: err.Error()}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"host": host}}
}

// ensureRouterForward params: {host, remotePort?}
// 戻り値: {localPort: int}
func opEnsureRouterForward(req masterReq) masterRes {
	host := strParam(req.Params, "host")
	if host == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host required"}
	}
	remotePort := intParam(req.Params, "remotePort")
	port, err := globalTunnelManager.ensureRouterForward(host, remotePort)
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: err.Error()}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"localPort": port}}
}

func opTunnelStatus(req masterReq) masterRes {
	st := globalTunnelManager.status()
	conv := make(map[string]interface{}, len(st))
	for k, v := range st {
		conv[k] = v
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"forwards": conv}}
}

func opTeardownAllTunnels(req masterReq) masterRes {
	globalTunnelManager.teardownAll()
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"status": "ok"}}
}

func strParam(p map[string]interface{}, key string) string {
	if v, ok := p[key].(string); ok {
		return v
	}
	return ""
}

func boolParam(p map[string]interface{}, key string) bool {
	if v, ok := p[key].(bool); ok {
		return v
	}
	return false
}

func intParam(p map[string]interface{}, key string) int {
	switch v := p[key].(type) {
	case int:
		return v
	case float64:
		return int(v)
	}
	return 0
}
