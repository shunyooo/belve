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
	"strings"
)

type ctrlReq struct {
	ID       string `json:"id"`
	Op       string `json:"op"`
	Path     string `json:"path,omitempty"`
	Path2    string `json:"path2,omitempty"`    // for rename (dst)
	Data     string `json:"data,omitempty"`     // for write
	Encoding string `json:"encoding,omitempty"` // utf8 (default) or base64
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
			defer func() {
				if r := recover(); r != nil {
					fmt.Fprintf(os.Stderr, "[belve-persist] control conn panic: %v\n", r)
				}
				c.Close()
			}()
			handleControlConn(c)
		}(conn)
	}
}

func handleControlConn(c net.Conn) {
	reader := bufio.NewReader(c)
	encoder := json.NewEncoder(c)
	// 同期処理 — 1 接続 = 1 in-flight。並行性が必要なら client 側で接続を増やす。
	// 並列にすると EOF 後に走る handler が close 済み conn に書こうとして
	// silently 落ちるバグ + ordering 保証が無いので reply の順序が乱れる。
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
			_ = encoder.Encode(ctrlRes{OK: false, Error: fmt.Sprintf("bad json: %v", err)})
			continue
		}
		res := safeDispatch(req)
		if err := encoder.Encode(res); err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] control write: %v\n", err)
			return
		}
	}
}

// dispatchOp を panic から守るラッパ。Handler が panic しても接続だけが
// fail せずエラー response を返してこの接続は生き残る。
func safeDispatch(req ctrlReq) (res ctrlRes) {
	defer func() {
		if r := recover(); r != nil {
			res = ctrlRes{ID: req.ID, OK: false, Error: fmt.Sprintf("handler panic: %v", r)}
		}
	}()
	return dispatchOp(req)
}

func dispatchOp(req ctrlReq) ctrlRes {
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
