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
	"os/exec"
	"path/filepath"
	"sync"
)

// Master が公開する API のバージョン。Belve.app は handshake でこの値を
// 確認し、想定と違ったら master を kill → spawn し直して新版に attach する
// (= broker の version negotiation 議論を Mac 側に持ってきた版)。
const macMasterVersion = "1.1"

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

// Push event (no `id`, has `type`). 長時間 op の進捗を返信用 conn にストリーム
// する用途で使う (rebuildSetup の belve-setup 出力等)。Belve.app 側はこの
// `type` を見て payload を route する。
type masterPush struct {
	Type    string                 `json:"type"`
	Payload map[string]interface{} `json:"payload,omitempty"`
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
		// Long-running op (rebuildSetup) は別 goroutine で動かして reader を
		// blocking しないようにする。短い op は逐次実行で OK。
		if req.Op == "rebuildSetup" {
			go func(req masterReq) {
				res := safeMasterDispatch(mc, req)
				_ = mc.write(res)
			}(req)
			continue
		}
		res := safeMasterDispatch(mc, req)
		if err := mc.write(res); err != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] write: %v\n", err)
			return
		}
	}
}

func safeMasterDispatch(mc *masterConn, req masterReq) (res masterRes) {
	defer func() {
		if r := recover(); r != nil {
			res = masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("handler panic: %v", r)}
		}
	}()
	return masterDispatch(mc, req)
}

func masterDispatch(mc *masterConn, req masterReq) masterRes {
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
	case "rebuildSetup":
		return opRebuildSetup(mc, req)
	case "transferImage":
		return opTransferImage(req)
	default:
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("unknown op: %s", req.Op)}
	}
}

// transferImage params: {host, isDevContainer, projShort, localPath}
// Mac 上の localPath を ssh stdin で remote (VM) または DevContainer 内に
// `/tmp/belve-clipboard/<basename>` として配置し remotePath を返す。
//
// SSH ControlMaster 経由なので新規 SSH session を消費しない (= MaxSessions
// 影響なし、port forward と相乗り)。
func opTransferImage(req masterReq) masterRes {
	p := req.Params
	host := strParam(p, "host")
	localPath := strParam(p, "localPath")
	if host == "" || localPath == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host/localPath required"}
	}
	isDC := boolParam(p, "isDevContainer")
	projShort := strParam(p, "projShort")
	if isDC && projShort == "" {
		return masterRes{ID: req.ID, OK: false, Error: "projShort required for devcontainer"}
	}

	filename := filepath.Base(localPath)
	remoteDir := "/tmp/belve-clipboard"
	remotePath := remoteDir + "/" + filename

	// remote 側で実行する shell command を組み立てる。
	// DevContainer の場合は VM 側で .env source して CID を取り、docker exec -i に
	// stdin をパイプ。Plain SSH は VM 側に直接書く。
	var sshCmd string
	if isDC {
		sshCmd = fmt.Sprintf(
			". $HOME/.belve/projects/%s.env && docker exec -i \"$CID\" sh -c %s",
			projShort,
			shellEscape(fmt.Sprintf("mkdir -p %s && cat > %s", remoteDir, remotePath)),
		)
	} else {
		sshCmd = fmt.Sprintf("mkdir -p %s && cat > %s", remoteDir, remotePath)
	}

	args := append([]string{}, sshOpts(host)...)
	args = append(args, host, sshCmd)
	cmd := exec.Command("ssh", args...)

	f, err := os.Open(localPath)
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("open local %s: %v", localPath, err)}
	}
	defer f.Close()
	cmd.Stdin = f

	out, err := cmd.CombinedOutput()
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("ssh transfer: %v: %s", err, string(out))}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"remotePath": remotePath}}
}

// rebuildSetup params: {projectId, host, workspacePath, projShort, binDir, forceRebuild?}
// devcontainer の setup を実行 + 進捗を `rebuildProgress` push event で stream する。
// forceRebuild=true なら旧 container 破壊 (= belve-setup --rebuild)。false なら
// 通常の belve-setup (cached .env あれば fast path、無ければ devcontainer up を新規実行)。
//
// 「Rebuild DevContainer」と「SSH → Open Remote DevContainer」両方の経路から
// 同じ UX (overlay + ライブログ) を提供するために共通化。
func opRebuildSetup(mc *masterConn, req masterReq) masterRes {
	p := req.Params
	projectID := strParam(p, "projectId")
	host := strParam(p, "host")
	workspacePath := strParam(p, "workspacePath")
	projShort := strParam(p, "projShort")
	binDir := strParam(p, "binDir")
	forceRebuild := boolParam(p, "forceRebuild")
	if projectID == "" || host == "" || projShort == "" || binDir == "" {
		return masterRes{ID: req.ID, OK: false, Error: "projectId/host/projShort/binDir required"}
	}

	// 1) Setup state を invalidate (= 次回 ensureSetup が再実行される)
	globalSetupManager.invalidate(projectID)

	// 2) Per-host lock 取って belve-setup を走らせる
	//    出力は line-buffered で push event として返信
	pushLine := func(phase, line string) {
		_ = mc.write(masterPush{
			Type: "rebuildProgress",
			Payload: map[string]interface{}{
				"projectId": projectID,
				"phase":     phase,
				"line":      line,
			},
		})
	}
	pushLine("starting", fmt.Sprintf("Acquiring host lock for %s…", host))

	hl := globalSetupManager.hostLock(host)
	hl.Lock()
	defer hl.Unlock()
	if forceRebuild {
		pushLine("running", "Starting devcontainer rebuild (this can take 30-120s)…")
	} else {
		pushLine("running", "Preparing container (this can take 30-120s on first run)…")
	}

	// 3) Deploy bundle (binary / scripts)
	if err := deployBundle(host, binDir); err != nil {
		pushLine("failed", fmt.Sprintf("deploy_bundle failed: %v", err))
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("deploy: %v", err)}
	}
	pushLine("running", "Bundle deployed.")

	// 4) belve-setup via SSH, stdout/stderr を line stream
	rebuildFlag := ""
	if forceRebuild {
		rebuildFlag = "--rebuild "
	}
	cmd := fmt.Sprintf("$HOME/.belve/bin/belve-setup %s--devcontainer --workspace %s --project-short %s",
		rebuildFlag, shellEscape(workspacePath), shellEscape(projShort))
	args := append([]string{}, sshOpts(host)...)
	args = append(args, host, cmd)
	c := exec.Command("ssh", args...)
	stdoutPipe, err := c.StdoutPipe()
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("stdout pipe: %v", err)}
	}
	stderrPipe, err := c.StderrPipe()
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("stderr pipe: %v", err)}
	}
	if err := c.Start(); err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("start: %v", err)}
	}
	streamLines := func(r io.Reader) {
		scanner := bufio.NewScanner(r)
		scanner.Buffer(make([]byte, 64*1024), 1024*1024)
		for scanner.Scan() {
			pushLine("running", scanner.Text())
		}
	}
	go streamLines(stdoutPipe)
	go streamLines(stderrPipe)
	waitErr := c.Wait()
	if waitErr != nil {
		pushLine("failed", fmt.Sprintf("Rebuild failed: %v", waitErr))
		return masterRes{ID: req.ID, OK: false, Error: waitErr.Error()}
	}
	pushLine("success", "Container ready.")

	// 5) Mark setup as ready in state manager so subsequent ensureSetup is fast-path
	//    (= Belve.app が PTY 再 spawn する直前に ensureSetup → 即返却)
	globalSetupManager.markReady(projectID)
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"projectId": projectID, "state": "ready"}}
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
