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
	"strings"
	"sync"
	"time"
)

// Master が公開する API のバージョン。Belve.app は handshake でこの値を
// 確認し、想定と違ったら master を kill → spawn し直して新版に attach する
// (= broker の version negotiation 議論を Mac 側に持ってきた版)。
const macMasterVersion = "1.6" // 1.6: captureRemotePane op 追加

// Master 起動時に記録する自身の binary identity。version 応答に含めて
// Belve.app 側が「app bundle 内の binary と違ったら respawn」判定に使う。
// macMasterVersion を上げ忘れても binary が変わっていれば respawn される
// 安全網 (= 金曜の stale master が今日の app と通信し続けた事故の対策)。
//
// mtime と size の組合せ。md5 は startup を遅らせる + crypto 不要なので避ける。
// build した瞬間に mtime + size の少なくともどちらかは確実に変わる。
var (
	masterBinaryMtime int64
	masterBinarySize  int64
)

func init() {
	if exe, err := os.Executable(); err == nil {
		if st, err := os.Stat(exe); err == nil {
			masterBinaryMtime = st.ModTime().Unix()
			masterBinarySize = st.Size()
		}
	}
}

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
	initTunnelManager()
	// Mux manager は常に初期化しておく (Phase 6)。誰も繋がなければ listener
	// すら起動しない (= lazy)。host 単位の listener は ensureSetup の成功時に
	// 起動する。
	globalMuxManager = newMuxManager(globalTunnelManager)
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
		return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{
			"version":     macMasterVersion,
			"pid":         fmt.Sprintf("%d", os.Getpid()),
			"binaryMtime": masterBinaryMtime,
			"binarySize":  masterBinarySize,
		}}
	case "ensureSetup":
		return opEnsureSetup(req)
	case "invalidateSetup":
		return opInvalidateSetup(req)
	case "invalidateAllSetups":
		return opInvalidateAllSetups(req)
	case "ensureControlMaster":
		return opEnsureControlMaster(req)
	case "tunnelStatus":
		return opTunnelStatus(req)
	case "teardownAllTunnels":
		return opTeardownAllTunnels(req)
	case "transferImage":
		return opTransferImage(req)
	case "resetHostHealth":
		return opResetHostHealth(req)
	case "listSessions":
		return opListSessions(req)
	case "killSession":
		return opKillSession(req)
	case "renameSession":
		return opRenameSession(req)
	case "listRemoteSessions":
		return opListRemoteSessions(req)
	case "captureRemotePane":
		return opCaptureRemotePane(req)
	default:
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("unknown op: %s", req.Op)}
	}
}

// transferImage params: {host, localPath}
// Mac 上の localPath を ssh stdin で remote (VM) 上に
// `/tmp/belve-clipboard/<basename>` として配置し remotePath を返す。
//
// SSH ControlMaster 経由なので新規 SSH session を消費しない (= MaxSessions
// 影響なし、port forward と相乗り)。
// resetHostHealth params: {host}
// Cmd+R / Retry ボタン経由で呼ばれる。host failure cache を即時クリア + stale な
// ControlMaster socket を `ssh -O exit` で掃除する。次回 ensureSetup で SSH 再試行。
func opResetHostHealth(req masterReq) masterRes {
	host := strParam(req.Params, "host")
	if host == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host required"}
	}
	globalHostHealth.reset(host)
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"host": host}}
}

func opTransferImage(req masterReq) masterRes {
	p := req.Params
	host := strParam(p, "host")
	localPath := strParam(p, "localPath")
	if host == "" || localPath == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host/localPath required"}
	}
	filename := filepath.Base(localPath)
	remoteDir := "/tmp/belve-clipboard"
	remotePath := remoteDir + "/" + filename

	// remote (VM) 側に直接書く。
	sshCmd := fmt.Sprintf("mkdir -p %s && cat > %s", remoteDir, remotePath)

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

// ensureSetup params: {projectId, host, workspacePath, projShort, binDir}
// 戻り値: {state: "ready"|"failed", error?: "..."}
func opEnsureSetup(req masterReq) masterRes {
	p := req.Params
	sreq := setupReq{
		ProjectID:     strParam(p, "projectId"),
		Host:          strParam(p, "host"),
		WorkspacePath: strParam(p, "workspacePath"),
		ProjShort:     strParam(p, "projShort"),
		BinDir:        strParam(p, "binDir"),
	}
	st, errStr := globalSetupManager.ensureSetup(sreq)
	// Setup 成功 host については mux listener も立てておく (Phase 6)。
	// listener 起動だけで yamux session の確立は lazy (= pane client が
	// 繋ぐまで spawn しない)。listener が無いと pane client の `-mux-via`
	// が "no such file" になるので、setup-ready のタイミングで作る。
	if st == setupReady && sreq.Host != "" && globalMuxManager != nil {
		if err := globalMuxManager.ensureListener(sreq.Host); err != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] mux listener (%s): %v\n", sreq.Host, err)
		}
	}
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

func opInvalidateAllSetups(req masterReq) masterRes {
	globalSetupManager.mu.Lock()
	n := len(globalSetupManager.projects)
	globalSetupManager.projects = map[string]*projectSetup{}
	globalSetupManager.mu.Unlock()
	return masterRes{ID: req.ID, OK: true, Result: map[string]int{"invalidated": n}}
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

func intParam(p map[string]interface{}, key string) int {
	switch v := p[key].(type) {
	case int:
		return v
	case float64:
		return int(v)
	}
	return 0
}

// listSessions: ローカルの belve-persist セッション一覧を返す。
// /tmp/belve-shell/sessions/*.sock を列挙し、daemon プロセスの生存確認を行う。
func opListSessions(req masterReq) masterRes {
	sessDir := "/tmp/belve-shell/sessions"
	entries, err := os.ReadDir(sessDir)
	if err != nil {
		return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"sessions": []interface{}{}}}
	}
	var sessions []map[string]interface{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sock") {
			continue
		}
		name := strings.TrimSuffix(e.Name(), ".sock")
		sockPath := filepath.Join(sessDir, e.Name())
		info, _ := e.Info()
		modTime := ""
		if info != nil {
			modTime = info.ModTime().Format(time.RFC3339)
		}
		// daemon が生きてるか確認 (socket に connect してすぐ close)
		alive := false
		if conn, err := net.DialTimeout("unix", sockPath, 500*time.Millisecond); err == nil {
			conn.Close()
			alive = true
		}
		sessions = append(sessions, map[string]interface{}{
			"name":    name,
			"socket":  sockPath,
			"modTime": modTime,
			"alive":   alive,
		})
	}
	if sessions == nil {
		sessions = []map[string]interface{}{}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"sessions": sessions}}
}

// listRemoteSessions: 指定 host 上の tmux セッションを ssh ControlMaster 経由で
// 列挙する (リモートプロジェクトのペイン追加チューザ用)。tmux 未起動 / セッション
// 無しは空一覧扱い。フォーマットはタブ区切り: name<TAB>windows<TAB>attached。
func opListRemoteSessions(req masterReq) masterRes {
	host := strParam(req.Params, "host")
	if host == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host required"}
	}
	// `\t` は Go 文字列上で実タブになり、tmux -F にそのまま渡るので出力も実タブ区切り。
	// フィールド: name / windows / attached / activity(epoch秒) / active pane の command。
	tmuxCmd := "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}\t#{pane_current_command}' 2>/dev/null || true"
	args := append([]string{}, sshOpts(host)...)
	args = append(args, host, tmuxCmd)
	out, err := exec.Command("ssh", args...).CombinedOutput()
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("ssh tmux ls: %v: %s", err, string(out))}
	}
	field := func(parts []string, i int) string {
		if i < len(parts) {
			return parts[i]
		}
		return ""
	}
	var sessions []map[string]interface{}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		name := parts[0]
		if name == "" {
			continue
		}
		sessions = append(sessions, map[string]interface{}{
			"name":     name,
			"windows":  field(parts, 1),
			"attached": field(parts, 2) != "0" && field(parts, 2) != "",
			"activity": field(parts, 3),
			"command":  field(parts, 4),
		})
	}
	if sessions == nil {
		sessions = []map[string]interface{}{}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"sessions": sessions}}
}

// shellSingleQuote は文字列を sh の単一引用符で安全に囲む (インジェクション防止)。
func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// captureRemotePane: 指定 host の tmux セッションの現在画面を plain text で返す
// (チューザで選択中セッションのプレビュー表示用)。`tmux capture-pane -p`。
func opCaptureRemotePane(req masterReq) masterRes {
	host := strParam(req.Params, "host")
	session := strParam(req.Params, "session")
	if host == "" || session == "" {
		return masterRes{ID: req.ID, OK: false, Error: "host and session required"}
	}
	tmuxCmd := fmt.Sprintf("tmux capture-pane -p -t %s 2>/dev/null || true", shellSingleQuote(session))
	args := append([]string{}, sshOpts(host)...)
	args = append(args, host, tmuxCmd)
	out, err := exec.Command("ssh", args...).CombinedOutput()
	if err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("ssh capture-pane: %v: %s", err, string(out))}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]interface{}{"content": string(out)}}
}

// killSession: 指定セッションの daemon を終了し、socket ファイルを削除する。
func opKillSession(req masterReq) masterRes {
	name := strParam(req.Params, "name")
	if name == "" {
		return masterRes{ID: req.ID, OK: false, Error: "name required"}
	}
	sockPath := filepath.Join("/tmp/belve-shell/sessions", name+".sock")
	// daemon に接続して終了を促す (接続後すぐ close → daemon は client count 0 で exit)
	// それでも駄目なら socket ファイルだけ削除
	if conn, err := net.DialTimeout("unix", sockPath, 500*time.Millisecond); err == nil {
		conn.Close()
	}
	// socket ファイル削除
	os.Remove(sockPath)
	// lock ファイルも掃除
	os.Remove(sockPath + ".lock")
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"name": name}}
}

// renameSession: セッションの socket ファイル (+ .pid / .lock) を付け替える。
// AF_UNIX の listen は inode に bind されているので、稼働中 daemon でも
// socket ファイルを rename すれば新パスで到達でき、daemon 側の変更は不要。
// 呼び出し側は「どの pane にも紐付いていない (= 未使用)」セッションだけを
// 対象にする前提 (in-use セッションはチューザで除外済み)。
func opRenameSession(req masterReq) masterRes {
	from := strParam(req.Params, "from")
	to := strParam(req.Params, "to")
	if from == "" || to == "" {
		return masterRes{ID: req.ID, OK: false, Error: "from and to required"}
	}
	// パス区切りや別ディレクトリへの脱出を防ぐ (basename のみ許可)。
	if from != filepath.Base(from) || to != filepath.Base(to) {
		return masterRes{ID: req.ID, OK: false, Error: "invalid session name"}
	}
	if from == to {
		return masterRes{ID: req.ID, OK: true, Result: map[string]string{"name": to}}
	}
	sessDir := "/tmp/belve-shell/sessions"
	fromSock := filepath.Join(sessDir, from+".sock")
	toSock := filepath.Join(sessDir, to+".sock")
	if _, err := os.Stat(fromSock); err != nil {
		return masterRes{ID: req.ID, OK: false, Error: "session not found: " + from}
	}
	if _, err := os.Stat(toSock); err == nil {
		return masterRes{ID: req.ID, OK: false, Error: "session already exists: " + to}
	}
	if err := os.Rename(fromSock, toSock); err != nil {
		return masterRes{ID: req.ID, OK: false, Error: fmt.Sprintf("rename failed: %v", err)}
	}
	// 付随ファイルも一緒に付け替える (存在すれば)。
	for _, suffix := range []string{".sock.pid", ".sock.lock"} {
		fromExtra := filepath.Join(sessDir, from+suffix)
		toExtra := filepath.Join(sessDir, to+suffix)
		if _, err := os.Stat(fromExtra); err == nil {
			os.Rename(fromExtra, toExtra)
		}
	}
	return masterRes{ID: req.ID, OK: true, Result: map[string]string{"name": to}}
}
