package main

// Control RPC server. Runs alongside the PTY broker on a separate TCP port
// so Mac-side providers can do filesystem / git ops without spawning a fresh
// `ssh host cmd` per call (= 5 秒 polling での flicker / latency 問題への根治).
//
// Wire format: NDJSON (newline-delimited JSON) bidirectional.
//   req:  {"id":"1","op":"ls","path":"/foo"}
//   res:  {"id":"1","ok":true,"result":{...}}
//   res:  {"id":"1","ok":false,"error":"..."}
//   push: {"type":"fsevent","watchId":"w1","path":"...","kind":"create"}
//
// Each connection is independent; each request runs in its own goroutine
// guarded by `defer recover()` so a buggy handler can't take down the
// process (which would also kill all PTY sessions on the host).

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/fsnotify/fsnotify"
)

type ctrlReq struct {
	ID       string   `json:"id"`
	Op       string   `json:"op"`
	Path     string   `json:"path,omitempty"`
	Path2    string   `json:"path2,omitempty"`    // for rename (dst)
	Data     string   `json:"data,omitempty"`     // for write
	Encoding string   `json:"encoding,omitempty"` // utf8 (default) or base64
	WatchID  string   `json:"watchId,omitempty"`  // for unwatch
	File     string   `json:"file,omitempty"`     // for gitDiff (relative file path within repo)
	Paths    []string `json:"paths,omitempty"`    // for gitCheckIgnore
	Args     []string `json:"args,omitempty"`     // for gitDiffBulk / gitChangedFiles
	LspID    string   `json:"lspId,omitempty"`    // for lspRequest / lspStop
	Language string   `json:"language,omitempty"` // for lspStart
	Method   string   `json:"method,omitempty"`   // for lspRequest (JSON-RPC method)
	Params   string   `json:"params,omitempty"`   // for lspRequest (JSON-RPC params as JSON string)
}

type ctrlRes struct {
	ID     string      `json:"id"`
	OK     bool        `json:"ok"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

type lsEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
	Mtime int64  `json:"mtime"` // unix seconds
}

type gitFileStatus struct {
	Status string `json:"status"`
	File   string `json:"file"`
}

// 接続ごとの状態。writer mutex (push event と response の同時書きを直列化) と
// アクティブな watcher を保持。接続が切れたら watcher は全部 close。
type connState struct {
	conn      net.Conn
	enc       *json.Encoder
	encMu     sync.Mutex
	watches   map[string]*fsnotify.Watcher
	watchesMu sync.Mutex
	lspProcs  map[string]*lspProcess
	lspMu     sync.Mutex
	closed    atomic.Bool
}

func (cs *connState) write(v interface{}) error {
	if cs.closed.Load() {
		return io.ErrClosedPipe
	}
	cs.encMu.Lock()
	defer cs.encMu.Unlock()
	return cs.enc.Encode(v)
}

func (cs *connState) shutdown() {
	cs.closed.Store(true)
	cs.watchesMu.Lock()
	for _, w := range cs.watches {
		_ = w.Close()
	}
	cs.watches = nil
	cs.watchesMu.Unlock()
	cs.lspMu.Lock()
	for _, lsp := range cs.lspProcs {
		lsp.stop()
	}
	cs.lspProcs = nil
	cs.lspMu.Unlock()
}

var nextWatchID atomic.Int64

func runControlServer(listenAddr string) {
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] control listen %s: %v\n", listenAddr, err)
		return
	}
	fmt.Fprintf(os.Stderr, "[belve-persist] control listening on %s\n", listenAddr)
	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] control accept: %v\n", err)
			continue
		}
		go func(c net.Conn) {
			cs := &connState{
				conn:    c,
				enc:     json.NewEncoder(c),
				watches:  map[string]*fsnotify.Watcher{},
				lspProcs: map[string]*lspProcess{},
			}
			defer func() {
				if r := recover(); r != nil {
					fmt.Fprintf(os.Stderr, "[belve-persist] control conn panic: %v\n", r)
				}
				cs.shutdown()
				c.Close()
			}()
			handleControlConn(cs)
		}(conn)
	}
}

func handleControlConn(cs *connState) {
	reader := bufio.NewReader(cs.conn)
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err != io.EOF {
				fmt.Fprintf(os.Stderr, "[belve-persist] control read: %v\n", err)
			}
			return
		}
		var req ctrlReq
		if err := json.Unmarshal(line, &req); err != nil {
			_ = cs.write(ctrlRes{OK: false, Error: fmt.Sprintf("bad json: %v", err)})
			continue
		}
		// 各 op を goroutine で並行処理する。Sync 処理だと 1 個遅い op (例:
		// 巨大 repo の gitDiffBulk が数秒) が来た時に同 connection の後続 polling
		// (ChangesView 3s × 数 ops) が全部 queue → Mac 側 RPC client の 5s timeout
		// 連発、という cascade を起こしていた。
		// `cs.write` は encMu で直列化されているので、複数 goroutine から同時に
		// response を投げても OK (id でクライアント側が match するので順不同で良い)。
		go func(req ctrlReq) {
			res := safeDispatch(cs, req)
			if err := cs.write(res); err != nil {
				fmt.Fprintf(os.Stderr, "[belve-persist] control write: %v\n", err)
			}
		}(req)
	}
}

// dispatchOp を panic から守るラッパ。Handler が panic しても接続だけが
// fail せずエラー response を返してこの接続は生き残る。
func safeDispatch(cs *connState, req ctrlReq) (res ctrlRes) {
	defer func() {
		if r := recover(); r != nil {
			res = ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("handler panic: %v", r)}
		}
	}()
	return dispatchOp(cs, req)
}

func dispatchOp(cs *connState, req ctrlReq) ctrlRes {
	switch req.Op {
	case "ping":
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"pong": "ok"}}
	case "pwd":
		return opPwd(req)
	case "ls":
		return opLs(req)
	case "stat":
		return opStat(req)
	case "read":
		return opRead(req)
	case "write":
		return opWrite(req)
	case "delete":
		return opDelete(req)
	case "mkdir":
		return opMkdir(req)
	case "rename":
		return opRename(req)
	case "gitBranch":
		return opGitBranch(req)
	case "gitStatus":
		return opGitStatus(req)
	case "gitDiff":
		return opGitDiff(req)
	case "gitCheckIgnore":
		return opGitCheckIgnore(req)
	case "gitDiffBulk":
		return opGitDiffBulk(req)
	case "gitChangedFiles":
		return opGitChangedFiles(req)
	case "gitLog":
		return opGitLog(req)
	case "watch":
		return opWatch(cs, req)
	case "unwatch":
		return opUnwatch(cs, req)
	case "lspStart":
		return opLspStart(cs, req)
	case "lspRequest":
		return opLspRequest(cs, req)
	case "lspStop":
		return opLspStop(cs, req)
	default:
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("unknown op: %s", req.Op)}
	}
}

// MARK: - Operations

func opPwd(req ctrlReq) ctrlRes {
	cwd, err := os.Getwd()
	if err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"cwd": cwd}}
}

func opLs(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	entries, err := os.ReadDir(p)
	if err != nil {
		return errRes(req.ID, err.Error())
	}
	out := make([]lsEntry, 0, len(entries))
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, lsEntry{
			Name:  e.Name(),
			IsDir: e.IsDir(),
			Size:  info.Size(),
			Mtime: info.ModTime().Unix(),
		})
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"entries": out}}
}

func opStat(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	info, err := os.Stat(p)
	if err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true, Result: lsEntry{
		Name:  info.Name(),
		IsDir: info.IsDir(),
		Size:  info.Size(),
		Mtime: info.ModTime().Unix(),
	}}
}

// opReadMaxBytes: 1 回の read op で返す上限。これを超えたらエラーで返す。
// 巨大ファイル (= core dump 等) の content を NDJSON で返すと encMu で直列化された
// 書き込みが長時間ブロックして同 connection の他 op (gitChangedFiles 等) が
// timeout する (= 2026-04-27 の cascade)。Editor / preview は数 MB が現実的上限なので
// 8 MB を上限にする (Markdown / source code / 設定ファイルは余裕で収まる)。
const opReadMaxBytes = 8 * 1024 * 1024

func opRead(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	// stat 先行: 巨大ファイルは ReadFile せず即エラー (= メモリも食わない)。
	if info, err := os.Stat(p); err == nil && info.Size() > opReadMaxBytes {
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("file too large: %d bytes (limit %d)", info.Size(), opReadMaxBytes)}
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return errRes(req.ID, err.Error())
	}
	if len(data) > opReadMaxBytes {
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("file too large: %d bytes (limit %d)", len(data), opReadMaxBytes)}
	}
	encoding := req.Encoding
	if encoding == "" {
		encoding = "utf8"
	}
	var content string
	if encoding == "base64" {
		content = base64.StdEncoding.EncodeToString(data)
	} else {
		content = string(data)
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{
		"content":  content,
		"encoding": encoding,
		"size":     len(data),
	}}
}

func opWrite(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	var data []byte
	if req.Encoding == "base64" {
		decoded, err := base64.StdEncoding.DecodeString(req.Data)
		if err != nil {
			return errRes(req.ID, "invalid base64")
		}
		data = decoded
	} else {
		data = []byte(req.Data)
	}
	if err := os.WriteFile(p, data, 0644); err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true}
}

func opDelete(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	if err := os.RemoveAll(p); err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true}
}

func opMkdir(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	if err := os.MkdirAll(p, 0755); err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true}
}

func opRename(req ctrlReq) ctrlRes {
	if req.Path == "" || req.Path2 == "" {
		return errRes(req.ID, "path and path2 required")
	}
	src := expandHome(req.Path)
	dst := expandHome(req.Path2)
	if err := os.Rename(src, dst); err != nil {
		return errRes(req.ID, err.Error())
	}
	return ctrlRes{ID: req.ID, OK: true}
}

func opGitBranch(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	cmd := exec.Command("git", "-C", p, "rev-parse", "--abbrev-ref", "HEAD")
	out, err := cmd.Output()
	if err != nil {
		// not a git repo etc — return ok with empty branch instead of error,
		// caller will treat empty as "no branch".
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"branch": ""}}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{
		"branch": strings.TrimSpace(string(out)),
	}}
}

func opGitStatus(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	cmd := exec.Command("git", "-C", p, "status", "--porcelain")
	out, err := cmd.Output()
	if err != nil {
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"files": []gitFileStatus{}}}
	}
	files := []gitFileStatus{}
	for _, line := range strings.Split(string(out), "\n") {
		if len(line) < 4 {
			continue
		}
		files = append(files, gitFileStatus{
			Status: strings.TrimSpace(line[:2]),
			File:   line[3:],
		})
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"files": files}}
}

// `git -C path diff -U0 -- file` を実行して raw 出力をそのまま返す。
// パース (@@ ヘッダ抽出) は Mac 側で既存ロジックを再利用するため、Go 側は
// 純粋に実行 + 文字列返しに徹する。
func opGitDiff(req ctrlReq) ctrlRes {
	if req.Path == "" || req.File == "" {
		return errRes(req.ID, "path and file required")
	}
	p := expandHome(req.Path)
	cmd := exec.Command("git", "-C", p, "diff", "-U0", "--", req.File)
	out, err := cmd.Output()
	if err != nil {
		// Not a git repo / no diff / error — return empty diff (caller treats
		// as "no hunks").
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"diff": ""}}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"diff": string(out)}}
}

// `git -C path check-ignore <paths...>` で ignored なものを返す。
// `--no-pager` 不要、`-z` (NUL 区切り) も小規模なので使わない。
func opGitCheckIgnore(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	if len(req.Paths) == 0 {
		return ctrlRes{ID: req.ID, OK: true, Result: map[string][]string{"ignored": {}}}
	}
	args := []string{"-C", expandHome(req.Path), "check-ignore", "--"}
	args = append(args, req.Paths...)
	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	// check-ignore は「なにも ignored じゃない」と exit 1 を返すので、
	// エラーは無視して output を見る。
	_ = err
	ignored := []string{}
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" {
			ignored = append(ignored, line)
		}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string][]string{"ignored": ignored}}
}

// Bulk diff: `git -C path diff [args...] 2>/dev/null` の全出力を返す。
// args は "--staged", "main...HEAD" 等の git diff 引数。
//
// 巨大 diff (= 数 MB-数十 MB) はそのまま返さず error にする。理由は opRead と同じ
// (encMu 直列化で同 connection の他 op が timeout する)。ChangesView は diff 表示
// なので 8 MB 超なら表示も実用的でないし、そもそも巨大 untracked file を含む
// repo (= core dump 等) 向けの保険。
func opGitDiffBulk(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	args := []string{"-C", p, "diff"}
	args = append(args, req.Args...)
	cmd := exec.Command("git", args...)
	out, err := cmd.Output()
	if err != nil {
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"diff": ""}}
	}
	if len(out) > opReadMaxBytes {
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("diff too large: %d bytes (limit %d)", len(out), opReadMaxBytes)}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"diff": string(out)}}
}

// Changed files list: args が空なら `git status --porcelain`、
// 非空なら `git diff [args] --name-status` を実行。
func opGitChangedFiles(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	var cmd *exec.Cmd
	if len(req.Args) == 0 {
		cmd = exec.Command("git", "-C", p, "status", "--porcelain")
	} else {
		args := []string{"-C", p, "diff"}
		args = append(args, req.Args...)
		args = append(args, "--name-status")
		cmd = exec.Command("git", args...)
	}
	out, err := cmd.Output()
	if err != nil {
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"files": []gitFileStatus{}}}
	}
	files := []gitFileStatus{}
	for _, line := range strings.Split(string(out), "\n") {
		if line == "" {
			continue
		}
		if len(req.Args) == 0 {
			// git status --porcelain: "XY filename"
			if len(line) < 4 {
				continue
			}
			files = append(files, gitFileStatus{
				Status: strings.TrimSpace(line[:2]),
				File:   line[3:],
			})
		} else {
			// git diff --name-status: "X\tfilename"
			parts := strings.SplitN(line, "\t", 2)
			if len(parts) < 2 {
				continue
			}
			files = append(files, gitFileStatus{
				Status: parts[0],
				File:   parts[1],
			})
		}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"files": files}}
}

type gitLogEntry struct {
	Hash    string `json:"hash"`
	Subject string `json:"subject"`
	Author  string `json:"author"`
	Date    string `json:"date"`
}

func opGitLog(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	maxCount := 50
	if len(req.Args) > 0 {
		if n, err := strconv.Atoi(req.Args[0]); err == nil && n > 0 {
			maxCount = n
		}
	}
	cmd := exec.Command("git", "-C", p, "log",
		fmt.Sprintf("--max-count=%d", maxCount),
		"--format=%H\x1f%s\x1f%an\x1f%ar")
	out, err := cmd.Output()
	if err != nil {
		return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"commits": []gitLogEntry{}, "unpushedFrom": ""}}
	}
	var commits []gitLogEntry
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\x1f", 4)
		if len(parts) < 4 {
			continue
		}
		commits = append(commits, gitLogEntry{
			Hash:    parts[0],
			Subject: parts[1],
			Author:  parts[2],
			Date:    parts[3],
		})
	}
	// Find push boundary: first commit that's on origin/<current-branch>
	unpushedFrom := ""
	branchCmd := exec.Command("git", "-C", p, "rev-parse", "--abbrev-ref", "HEAD")
	if branchOut, err := branchCmd.Output(); err == nil {
		branch := strings.TrimSpace(string(branchOut))
		remote := "origin/" + branch
		unpushedCmd := exec.Command("git", "-C", p, "rev-parse", remote)
		if remoteOut, err := unpushedCmd.Output(); err == nil {
			unpushedFrom = strings.TrimSpace(string(remoteOut))
		}
	}
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"commits": commits, "unpushedFrom": unpushedFrom}}
}

// MARK: - Watch

// fsevent push message — sent over the same NDJSON stream, distinguished
// from req/res by lack of `id` field (and presence of `type`).
type fsEvent struct {
	Type    string `json:"type"`    // "fsevent"
	WatchID string `json:"watchId"` // matches the id returned by `watch`
	Path    string `json:"path"`    // absolute path of the changed entry
	Kind    string `json:"kind"`    // create | modify | delete | rename | chmod
}

func opWatch(cs *connState, req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return errRes(req.ID, "fsnotify init: "+err.Error())
	}
	if err := w.Add(p); err != nil {
		_ = w.Close()
		return errRes(req.ID, err.Error())
	}
	id := "w" + strconv.FormatInt(nextWatchID.Add(1), 10)
	cs.watchesMu.Lock()
	if cs.watches == nil {
		cs.watches = map[string]*fsnotify.Watcher{}
	}
	cs.watches[id] = w
	cs.watchesMu.Unlock()

	// Pump events → push messages on the same connection. Goroutine exits
	// when the watcher is closed (either via `unwatch` or connection shutdown).
	go func(watchID string, watcher *fsnotify.Watcher) {
		for {
			select {
			case ev, ok := <-watcher.Events:
				if !ok {
					return
				}
				kind := mapFsKind(ev.Op)
				if kind == "" {
					continue
				}
				_ = cs.write(fsEvent{
					Type:    "fsevent",
					WatchID: watchID,
					Path:    ev.Name,
					Kind:    kind,
				})
			case err, ok := <-watcher.Errors:
				if !ok {
					return
				}
				fmt.Fprintf(os.Stderr, "[belve-persist] watch err id=%s: %v\n", watchID, err)
			}
		}
	}(id, w)

	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"watchId": id}}
}

func opUnwatch(cs *connState, req ctrlReq) ctrlRes {
	if req.WatchID == "" {
		return errRes(req.ID, "watchId required")
	}
	cs.watchesMu.Lock()
	w := cs.watches[req.WatchID]
	delete(cs.watches, req.WatchID)
	cs.watchesMu.Unlock()
	if w == nil {
		return errRes(req.ID, "no such watch")
	}
	_ = w.Close()
	return ctrlRes{ID: req.ID, OK: true}
}

// fsnotify Op → external "kind" string. Empty = ignore (e.g., chmod-only).
func mapFsKind(op fsnotify.Op) string {
	switch {
	case op&fsnotify.Create != 0:
		return "create"
	case op&fsnotify.Write != 0:
		return "modify"
	case op&fsnotify.Remove != 0:
		return "delete"
	case op&fsnotify.Rename != 0:
		return "rename"
	default:
		return "" // chmod is noisy & not useful for the file tree
	}
}

// MARK: - Helpers

func errRes(id, msg string) ctrlRes {
	return ctrlRes{ID: id, OK: false, Error: msg}
}

// `~/path` / `~` を $HOME に展開。Mac から絶対パスで来る想定だが、ユーザーが
// 設定 UI で `~/repo` 入力できるためサポートする。
func expandHome(p string) string {
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

// --- LSP Process Management ---

var nextLspID atomic.Int64

type lspProcess struct {
	cmd      *exec.Cmd
	stdin    io.WriteCloser
	stdout   *bufio.Reader
	mu       sync.Mutex
	nextID   int
	pending  map[int]chan json.RawMessage
	language string
}

func (lp *lspProcess) stop() {
	lp.mu.Lock()
	defer lp.mu.Unlock()
	if lp.cmd != nil && lp.cmd.Process != nil {
		// Send shutdown + exit
		lp.writeRequest("shutdown", nil)
		lp.writeNotification("exit", nil)
		time.AfterFunc(3*time.Second, func() {
			if lp.cmd.Process != nil {
				lp.cmd.Process.Kill()
			}
		})
	}
}

func (lp *lspProcess) writeRequest(method string, params interface{}) (json.RawMessage, error) {
	lp.mu.Lock()
	id := lp.nextID
	lp.nextID++
	ch := make(chan json.RawMessage, 1)
	lp.pending[id] = ch
	lp.mu.Unlock()

	msg := map[string]interface{}{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		msg["params"] = params
	}
	if err := lp.writeMessage(msg); err != nil {
		lp.mu.Lock()
		delete(lp.pending, id)
		lp.mu.Unlock()
		return nil, err
	}

	select {
	case result := <-ch:
		return result, nil
	case <-time.After(10 * time.Second):
		lp.mu.Lock()
		delete(lp.pending, id)
		lp.mu.Unlock()
		return nil, fmt.Errorf("LSP request timeout: %s", method)
	}
}

func (lp *lspProcess) writeNotification(method string, params interface{}) {
	msg := map[string]interface{}{"jsonrpc": "2.0", "method": method}
	if params != nil {
		msg["params"] = params
	}
	lp.writeMessage(msg)
}

func (lp *lspProcess) writeMessage(msg map[string]interface{}) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	header := fmt.Sprintf("Content-Length: %d\r\n\r\n", len(data))
	_, err = lp.stdin.Write([]byte(header))
	if err != nil {
		return err
	}
	_, err = lp.stdin.Write(data)
	return err
}

func (lp *lspProcess) readLoop() {
	for {
		// Read Content-Length header
		line, err := lp.stdout.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "Content-Length:") {
			continue
		}
		lengthStr := strings.TrimSpace(strings.TrimPrefix(line, "Content-Length:"))
		length, err := strconv.Atoi(lengthStr)
		if err != nil {
			continue
		}
		// Read blank line
		lp.stdout.ReadString('\n')
		// Read body
		body := make([]byte, length)
		_, err = io.ReadFull(lp.stdout, body)
		if err != nil {
			return
		}
		var msg map[string]json.RawMessage
		if err := json.Unmarshal(body, &msg); err != nil {
			continue
		}
		// Dispatch response
		if idRaw, ok := msg["id"]; ok {
			var id int
			if json.Unmarshal(idRaw, &id) == nil {
				lp.mu.Lock()
				if ch, exists := lp.pending[id]; exists {
					delete(lp.pending, id)
					if result, ok := msg["result"]; ok {
						ch <- result
					} else {
						ch <- nil
					}
				}
				lp.mu.Unlock()
			}
		}
	}
}

func findLspServer(language, rootPath string) (string, []string, error) {
	var names []string
	var args []string
	switch language {
	case "python":
		names = []string{"pyright-langserver", "pylsp"}
		args = []string{"--stdio"}
	case "typescript", "javascript":
		names = []string{"typescript-language-server"}
		args = []string{"--stdio"}
	default:
		return "", nil, fmt.Errorf("unsupported language: %s", language)
	}
	searchDirs := []string{"/usr/local/bin", "/usr/bin", "/root/.local/bin", "/root/.npm-global/bin"}
	if home, err := os.UserHomeDir(); err == nil {
		searchDirs = append(searchDirs, filepath.Join(home, ".local/bin"))
		searchDirs = append(searchDirs, filepath.Join(home, ".npm-global/bin"))
	}
	// Search project .venv (common for Python projects using uv/poetry)
	if rootPath != "" {
		venvBin := filepath.Join(rootPath, ".venv", "bin")
		searchDirs = append([]string{venvBin}, searchDirs...)
	}
	for _, name := range names {
		for _, dir := range searchDirs {
			p := filepath.Join(dir, name)
			if _, err := os.Stat(p); err == nil {
				return p, args, nil
			}
		}
		// which
		out, err := exec.Command("which", name).Output()
		if err == nil {
			p := strings.TrimSpace(string(out))
			if p != "" {
				return p, args, nil
			}
		}
	}
	return "", nil, fmt.Errorf("LSP server not found for %s (tried: %v)", language, names)
}

func opLspStart(cs *connState, req ctrlReq) ctrlRes {
	language := req.Language
	rootPath := expandHome(req.Path)
	if language == "" {
		return errRes(req.ID, "language required")
	}
	if rootPath == "" {
		return errRes(req.ID, "path required")
	}

	execPath, args, err := findLspServer(language, rootPath)
	if err != nil {
		return ctrlRes{ID: req.ID, OK: false, Error: err.Error()}
	}

	cmd := exec.Command(execPath, args...)
	cmd.Dir = rootPath
	stdinPipe, _ := cmd.StdinPipe()
	stdoutPipe, _ := cmd.StdoutPipe()
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("start failed: %v", err)}
	}

	lp := &lspProcess{
		cmd:      cmd,
		stdin:    stdinPipe,
		stdout:   bufio.NewReaderSize(stdoutPipe, 256*1024),
		pending:  make(map[int]chan json.RawMessage),
		language: language,
	}
	go lp.readLoop()

	// Send initialize
	rootURI := "file://" + rootPath
	initParams := map[string]interface{}{
		"processId": os.Getpid(),
		"rootUri":   rootURI,
		"capabilities": map[string]interface{}{
			"textDocument": map[string]interface{}{
				"hover":      map[string]interface{}{"contentFormat": []string{"markdown", "plaintext"}},
				"definition": map[string]interface{}{},
			},
		},
	}
	_, err = lp.writeRequest("initialize", initParams)
	if err != nil {
		cmd.Process.Kill()
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("initialize failed: %v", err)}
	}
	lp.writeNotification("initialized", map[string]interface{}{})

	id := fmt.Sprintf("lsp%d", nextLspID.Add(1))
	cs.lspMu.Lock()
	if cs.lspProcs == nil {
		cs.lspProcs = map[string]*lspProcess{}
	}
	cs.lspProcs[id] = lp
	cs.lspMu.Unlock()

	fmt.Fprintf(os.Stderr, "[belve-persist][lsp] started %s server (id=%s) at %s\n", language, id, rootPath)
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]string{"lspId": id}}
}

func opLspRequest(cs *connState, req ctrlReq) ctrlRes {
	cs.lspMu.Lock()
	lp := cs.lspProcs[req.LspID]
	cs.lspMu.Unlock()
	if lp == nil {
		return errRes(req.ID, "LSP server not found: "+req.LspID)
	}

	var params interface{}
	if req.Params != "" {
		json.Unmarshal([]byte(req.Params), &params)
	}

	result, err := lp.writeRequest(req.Method, params)
	if err != nil {
		return ctrlRes{ID: req.ID, OK: false, Error: err.Error()}
	}
	// Return raw JSON result
	return ctrlRes{ID: req.ID, OK: true, Result: map[string]interface{}{"result": string(result)}}
}

func opLspStop(cs *connState, req ctrlReq) ctrlRes {
	cs.lspMu.Lock()
	lp := cs.lspProcs[req.LspID]
	delete(cs.lspProcs, req.LspID)
	cs.lspMu.Unlock()
	if lp != nil {
		lp.stop()
		fmt.Fprintf(os.Stderr, "[belve-persist][lsp] stopped %s server (id=%s)\n", lp.language, req.LspID)
	}
	return ctrlRes{ID: req.ID, OK: true}
}
