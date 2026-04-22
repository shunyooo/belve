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
				watches: map[string]*fsnotify.Watcher{},
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
		res := safeDispatch(cs, req)
		if err := cs.write(res); err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] control write: %v\n", err)
			return
		}
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
	case "watch":
		return opWatch(cs, req)
	case "unwatch":
		return opUnwatch(cs, req)
	default:
		return ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("unknown op: %s", req.Op)}
	}
}

// MARK: - Operations

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

func opRead(req ctrlReq) ctrlRes {
	if req.Path == "" {
		return errRes(req.ID, "path required")
	}
	p := expandHome(req.Path)
	data, err := os.ReadFile(p)
	if err != nil {
		return errRes(req.ID, err.Error())
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
