// belve-persist: minimal process persistence (dtach-like).
// Full PTY passthrough: no mouse/OSC interference.
//
// Create + attach: belve-persist -socket /path -command /bin/bash
// Attach only:     belve-persist -socket /path

package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// withSpawnLock: 同 socket への spawn-on-demand を排他化する。複数 client が
// 同時に「daemon 不在 → spawn」を実行して複数 daemon が立ち上がる TOCTOU
// race を防ぐ。lockFn 内で tryAttach を re-check することで、待ってる間に
// 他クライアントが spawn し終えてた場合は重複 spawn を skip できる。
//
// 取れない場合 (= flock サポートしてない FS 等) は best effort で fn を実行。
func withSpawnLock(socketPath string, fn func()) {
	lockPath := socketPath + ".lock"
	// 親 dir 作成 (socketPath が /tmp/foo/bar.sock の時)
	_ = os.MkdirAll(filepath.Dir(lockPath), 0o755)
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		fn()
		return
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		fn()
		return
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
	fn()
}

// watchParent: env var BELVE_PARENT_PID にセットされてる PID が消えたら自分も exit。
// Belve.app から spawn された daemon / client が、parent (Belve.app) のクラッシュ後
// orphan として残り続ける問題を構造的に解消する。
//
// セットされてない場合 (= 自前で起動された container broker / mac-master 等) は
// no-op。明示的に opt-in する設計なので予期しない自殺はしない。
//
// 1s 周期で kill(pid, 0) を打って ESRCH が返れば parent 消滅と判定。
func watchParent() {
	pidStr := os.Getenv("BELVE_PARENT_PID")
	if pidStr == "" {
		return
	}
	pid, err := strconv.Atoi(pidStr)
	if err != nil || pid <= 1 {
		return
	}
	go func() {
		for {
			if err := syscall.Kill(pid, 0); err != nil {
				// ESRCH (no such process) or EPERM — どちらも即 exit して問題なし
				// (= parent 消滅 or PID 再利用で別所有者になってる)。
				fmt.Fprintf(os.Stderr, "[belve-persist] parent pid=%d gone (%v); exiting\n", pid, err)
				os.Exit(0)
			}
			time.Sleep(1 * time.Second)
		}
	}()
}

const (
	msgData    byte = 0
	msgResize  byte = 1
	msgSession byte = 2 // payload: session name (UTF-8)
)

func main() {
	socketPath := flag.String("socket", "", "Unix socket path")
	command := flag.String("command", "", "command to run (creates session)")
	daemon := flag.Bool("daemon", false, "run as daemon master (internal)")
	initCols := flag.Int("cols", 0, "initial PTY columns")
	initRows := flag.Int("rows", 0, "initial PTY rows")
	tcpListen := flag.String("tcplisten", "", "TCP listen address for broker mode (e.g. 0.0.0.0:19222)")
	tcpBackend := flag.String("tcpbackend", "", "TCP backend address (e.g. 172.17.0.2:19222)")
	sessionName := flag.String("session", "", "session name for TCP multiplexing")
	// 接続直後に router に投げる JSON preamble の projShort。指定があれば
	// MSG_INIT の前に `{"projShort":"X","kind":"pty"}\n` を送る。router が
	// 居る環境 (Phase B 以降) で必須。空なら preamble 送らない (legacy /
	// 直接 broker に繋ぐケース、後方互換のため残す)。
	routeProjShort := flag.String("route", "", "router preamble projShort (Phase B router mode)")
	// Control RPC port (separate from PTY broker). Mac-side providers use this
	// to do filesystem / git ops without spawning a fresh `ssh host cmd` per
	// call (= eliminates 5s polling flicker / latency).
	ctrlListen := flag.String("controllisten", "", "TCP listen address for control RPC (e.g. 0.0.0.0:19224)")
	// Router mode: VM 上の単一エンドポイントとして PTY + control 両方を受け、
	// preamble に従って container broker / VM-local broker に proxy する。
	// この 1 ポートだけ Mac から SSH forward すれば全 project を捌ける。
	routerListen := flag.String("router", "", "TCP listen address for router mode (e.g. 0.0.0.0:19200)")
	// Mac master mode: Belve.app から Unix socket で IPC を受け、project setup /
	// tunnel / session を一元管理する。詳細は docs/notes/2026-04-23-mac-master-design.md。
	macMaster := flag.String("mac-master", "", "Unix socket path for Mac master mode (e.g. /tmp/belve-master.sock)")
	flag.Parse()

	// Parent 死活監視 (env BELVE_PARENT_PID 必要)。spawn 元が exit したら自分も exit。
	// orphan 累積を構造的に防ぐ。Belve.app から spawn される client / daemon は env
	// 渡される、container broker や mac-master は env 渡されないので no-op。
	watchParent()

	// Mac master mode is foreground (= 単一責務、別 mode と組まない)。
	if *macMaster != "" {
		runMacMaster(*macMaster)
		return
	}

	// Router mode is foreground if it's the only role.
	if *routerListen != "" {
		if *tcpListen == "" && *tcpBackend == "" && *socketPath == "" && *ctrlListen == "" {
			runRouter(*routerListen)
			return
		}
		go runRouter(*routerListen)
	}

	// Control listener runs as a background goroutine alongside whatever main
	// mode (broker / tcpbackend / classic) is active. Crashes are isolated
	// per-connection via defer-recover in `runControlServer`.
	// Special case: if controllisten is the ONLY thing specified, run the
	// control server in the foreground (= dedicated control-only process).
	if *ctrlListen != "" {
		if *tcpListen == "" && *tcpBackend == "" && *socketPath == "" {
			runControlServer(*ctrlListen)
			return
		}
		go runControlServer(*ctrlListen)
	}

	// TCP broker mode (container side)
	if *tcpListen != "" {
		if *command == "" {
			fmt.Fprintln(os.Stderr, "tcplisten requires -command")
			os.Exit(1)
		}
		runTCPBroker(*tcpListen, *command, flag.Args(), uint16(*initCols), uint16(*initRows))
		return
	}

	// TCP backend mode (host side) — host persist daemon bridges Unix socket ↔ TCP
	if *tcpBackend != "" {
		if *socketPath == "" || *sessionName == "" {
			fmt.Fprintln(os.Stderr, "tcpbackend requires -socket and -session")
			os.Exit(1)
		}
		// `-daemon` 付きで来たら master 本体として起動 (= forked child)。
		// それ以外は client として、必要なら daemon を spawn してから attach する
		// (= 旧 belve-launcher.sh の per-pane orchestration を内蔵化、Phase 4)。
		if *daemon {
			runMasterTCPBackend(*socketPath, *tcpBackend, *sessionName, *routeProjShort, uint16(*initCols), uint16(*initRows))
			return
		}
		// 1) 既存 master があれば attach
		if tryAttach(*socketPath) {
			return
		}
		// 2) Spawn を flock で排他。複数クライアント同時起動でも daemon は 1 個だけ。
		withSpawnLock(*socketPath, func() {
			// re-check: 待ってる間に他 client が spawn し終えた可能性
			if tryAttach(*socketPath) {
				return
			}
			_ = os.Remove(*socketPath)
			spawnTCPBackendDaemon(*socketPath, *tcpBackend, *sessionName, *routeProjShort, *initCols, *initRows)
		})
		// 3) socket が現れるまで待って attach
		for i := 0; i < 50; i++ {
			if _, err := os.Stat(*socketPath); err == nil {
				if tryAttach(*socketPath) {
					return
				}
			}
			time.Sleep(100 * time.Millisecond)
		}
		fmt.Fprintln(os.Stderr, "tcpbackend daemon did not become ready")
		os.Exit(1)
	}

	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "usage: belve-persist -socket <path> [-command <cmd> [args...]]")
		os.Exit(1)
	}

	// Internal: run as daemon master
	if *daemon && *command != "" {
		args := flag.Args()
		if len(args) == 0 {
			runMaster(*socketPath, "/bin/sh", []string{"-c", *command}, uint16(*initCols), uint16(*initRows))
		} else {
			runMaster(*socketPath, *command, args, uint16(*initCols), uint16(*initRows))
		}
		return
	}

	// Try attach to existing session
	if tryAttach(*socketPath) {
		return
	}

	if *command == "" {
		fmt.Fprintln(os.Stderr, "no existing session; specify -command to create one")
		os.Exit(1)
	}

	// Spawn master as background daemon, then attach as client
	args := flag.Args()
	var cmdArgs []string
	if len(args) == 0 {
		cmdArgs = []string{"/bin/sh", "-c", *command}
	} else {
		cmdArgs = append([]string{*command}, args...)
	}
	withSpawnLock(*socketPath, func() {
		// re-check: 待ってる間に他 client が spawn し終えた可能性
		if tryAttach(*socketPath) {
			return
		}
		spawnDaemon(*socketPath, cmdArgs, *initCols, *initRows)
	})

	// Wait for socket, then attach
	for i := 0; i < 50; i++ {
		time.Sleep(100 * time.Millisecond)
		if tryAttach(*socketPath) {
			return
		}
	}
	fmt.Fprintln(os.Stderr, "timeout waiting for session")
	os.Exit(1)
}

func runMaster(socketPath, command string, args []string, cols, rows uint16) {
	// Always kill old daemons for this socket, then take over.
	killOldDaemons(socketPath)
	os.Remove(socketPath)
	writePidFile(socketPath)

	// Ignore SIGHUP to survive SSH/docker disconnects
	signal.Ignore(syscall.SIGHUP)

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(1)
	}

	var mu sync.Mutex
	var clients []net.Conn
	const replayMax = 4 * 1024 * 1024
	var replayBuf []byte
	var currentPtyFile *os.File
	var currentPtyFd uintptr

	addClient := func(c net.Conn) {
		mu.Lock()
		if len(replayBuf) > 0 {
			writeReplayChunks(c, replayBuf)
		}
		clients = append(clients, c)
		mu.Unlock()
	}
	removeClient := func(c net.Conn) {
		mu.Lock()
		for i, cl := range clients {
			if cl == c {
				clients = append(clients[:i], clients[i+1:]...)
				break
			}
		}
		mu.Unlock()
	}
	broadcast := func(data []byte) {
		mu.Lock()
		replayBuf = append(replayBuf, data...)
		if len(replayBuf) > replayMax {
			replayBuf = replayBuf[len(replayBuf)-replayMax:]
		}
		for _, c := range clients {
			writeMsg(c, msgData, data)
		}
		mu.Unlock()
		os.Stdout.Write(data)
	}

	// Accept socket clients
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				break
			}
			addClient(conn)
			go func(c net.Conn) {
				defer func() {
					removeClient(c)
					c.Close()
				}()
				for {
					t, payload, err := readMsg(c)
					if err != nil {
						break
					}
					switch t {
					case msgData:
						mu.Lock()
						pf := currentPtyFile
						mu.Unlock()
						if pf != nil {
							pf.Write(payload)
						}
					case msgResize:
						if len(payload) == 4 {
							c := binary.BigEndian.Uint16(payload[0:2])
							r := binary.BigEndian.Uint16(payload[2:4])
							mu.Lock()
							if currentPtyFd != 0 {
								setPtySize(currentPtyFd, c, r)
							}
							// Update last known size for respawn
							cols = c
							rows = r
							mu.Unlock()
							f, _ := os.OpenFile("/tmp/belve-persist-resize.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
							if f != nil {
								fmt.Fprintf(f, "%s resize: cols=%d rows=%d\n", time.Now().Format(time.RFC3339), c, r)
								f.Close()
							}
						}
					}
				}
			}(conn)
		}
	}()

	// Child spawn/respawn loop
	const maxRespawns = 10
	respawnCount := 0
	for {
		ptyFile, ttyPath, err := openPTY()
		if err != nil {
			fmt.Fprintf(os.Stderr, "openpty: %v\n", err)
			os.Exit(1)
		}
		if cols > 0 && rows > 0 {
			setPtySize(ptyFile.Fd(), cols, rows)
		}
		ttyFile, err := os.OpenFile(ttyPath, os.O_RDWR, 0)
		if err != nil {
			fmt.Fprintf(os.Stderr, "open tty: %v\n", err)
			os.Exit(1)
		}

		cmd := exec.Command(command, args...)
		cmd.Stdin = ttyFile
		cmd.Stdout = ttyFile
		cmd.Stderr = ttyFile
		cmd.SysProcAttr = setSysProcAttr(ttyFile)
		cmd.Env = os.Environ()
		if err := cmd.Start(); err != nil {
			fmt.Fprintf(os.Stderr, "exec: %v\n", err)
			os.Exit(1)
		}
		childPid = cmd.Process.Pid
		ttyFile.Close()

		mu.Lock()
		currentPtyFile = ptyFile
		currentPtyFd = ptyFile.Fd()
		mu.Unlock()

		// PTY → broadcast
		ptyDone := make(chan struct{})
		go func(pf *os.File) {
			defer close(ptyDone)
			buf := make([]byte, 32*1024)
			for {
				n, err := pf.Read(buf)
				if n > 0 {
					data := make([]byte, n)
					copy(data, buf[:n])
					broadcast(data)
				}
				if err != nil {
					break
				}
			}
		}(ptyFile)

		// Wait for child
		waitErr := cmd.Wait()
		<-ptyDone // wait for PTY reader to finish
		ptyFile.Close()

		mu.Lock()
		currentPtyFile = nil
		currentPtyFd = 0
		mu.Unlock()

		// Determine exit code
		exitCode := 0
		exitSignal := ""
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				if status.Signaled() {
					exitSignal = status.Signal().String()
				}
			}
		}

		// Log exit
		logExitDiagnostics(socketPath, childPid, waitErr, exitCode, exitSignal)

		// Decide whether to respawn — only on SIGKILL (= external kill).
		// Old behavior also respawned on docker-exec daemon death, but that
		// path is gone (Phase B uses container-internal broker via runTCPBroker).
		if respawnCount < maxRespawns && exitCode == 137 {
			respawnCount++
			statusMessage := "Remote terminal crashed (SIGKILL). Restarting shell..."
			msg := fmt.Sprintf("\r\n\x1b[33m[belve] remote terminal crashed (SIGKILL), restarting shell... (%d/%d)\x1b[0m\r\n",
				respawnCount, maxRespawns)
			notice := belveNoticeData(statusMessage, msg)
			mu.Lock()
			replayBuf = nil
			for _, c := range clients {
				writeMsg(c, msgData, notice)
			}
			mu.Unlock()
			time.Sleep(1 * time.Second)
			continue
		}

		break
	}

	listener.Close()
	os.Remove(socketPath + ".pid")
}

func logExitDiagnostics(socketPath string, pid int, err error, exitCode int, exitSignal string) {
	logFile, _ := os.OpenFile("/tmp/belve-persist-exit.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if logFile == nil {
		return
	}
	defer logFile.Close()

	procSnapshot := ""
	if out, e := exec.Command("ps", "aux", "--sort=-start_time").Output(); e == nil {
		lines := 0
		for _, b := range out {
			if b == '\n' {
				lines++
			}
			if lines > 20 {
				break
			}
			procSnapshot += string(b)
		}
	}
	memInfo := ""
	if out, e := exec.Command("sh", "-c", "cat /proc/meminfo 2>/dev/null | head -3").Output(); e == nil {
		memInfo = string(out)
	}
	fmt.Fprintf(logFile, "=== %s master child-exit ===\nsocket=%s childPid=%d err=%v exitCode=%d signal=%s\n--- memory ---\n%s--- top processes ---\n%s\n",
		time.Now().Format(time.RFC3339), socketPath, pid, err, exitCode, exitSignal, memInfo, procSnapshot)
}

// --- TCP broker (container side) ---

type tcpSession struct {
	name      string
	mu        sync.Mutex
	ptyFile   *os.File
	ptyFd     uintptr
	childPid  int
	clients   []net.Conn
	replayBuf []byte
	cols, rows uint16
	command   string
	args      []string
	extraEnv  []string // per-session env (BELVE_PANE_ID, BELVE_PROJECT_ID, ...)
	alive     bool // false after child exits without respawn
	// Instrumentation: total bytes emitted to the session and total bytes
	// discarded by the ring-buffer truncation. Helps answer "does the replay
	// buffer actually fill up in practice?" without interfering with session
	// behaviour.
	bytesEmitted  uint64
	bytesDiscarded uint64
	lastStatLog   time.Time
	truncations   uint64
}

// 4 MiB per session. Measured: at 64 KiB, claude code's rich output kept only
// ~12% of emitted bytes across a multi-minute session; at 4 MiB the same
// traffic pattern stays 100% retained. Memory cost is bounded by the number
// of live sessions on the host (~10 → 40 MiB).
const tcpReplayMax = 4 * 1024 * 1024


func (s *tcpSession) addClient(c net.Conn) {
	s.mu.Lock()
	if len(s.replayBuf) > 0 {
		writeReplayChunks(c, s.replayBuf)
	}
	s.clients = append(s.clients, c)
	s.mu.Unlock()
}

func (s *tcpSession) removeClient(c net.Conn) {
	s.mu.Lock()
	for i, cl := range s.clients {
		if cl == c {
			s.clients = append(s.clients[:i], s.clients[i+1:]...)
			break
		}
	}
	s.mu.Unlock()
}

func (s *tcpSession) broadcast(data []byte) {
	s.mu.Lock()
	s.bytesEmitted += uint64(len(data))
	// Naive `\r` collapse was attempted here but broke claude-code — its TUI
	// relies on `\033[<n>A` cursor-up sequences that got silently dropped
	// alongside the `\r` rollback, leaving the terminal in a cursor state
	// the replay couldn't reconstruct. Keep raw bytes; proper collapse needs
	// a virtual-terminal implementation (vterm) that tracks cursor state.
	s.replayBuf = append(s.replayBuf, data...)
	if len(s.replayBuf) > tcpReplayMax {
		excess := uint64(len(s.replayBuf) - tcpReplayMax)
		s.bytesDiscarded += excess
		s.truncations++
		s.replayBuf = s.replayBuf[len(s.replayBuf)-tcpReplayMax:]
	}
	// Only log when we actually had to discard — steady-state buffer use
	// (nothing dropped) isn't interesting. Throttle to 60 s so a busy
	// session doesn't spam the broker log.
	if s.bytesDiscarded > 0 && time.Since(s.lastStatLog) > 60*time.Second {
		log.Printf("[replay] session=%q emitted=%d discarded=%d trunc=%d bufLen=%d pct_kept=%.1f%%",
			s.name, s.bytesEmitted, s.bytesDiscarded, s.truncations, len(s.replayBuf),
			100.0*float64(s.bytesEmitted-s.bytesDiscarded)/float64(s.bytesEmitted))
		s.lastStatLog = time.Now()
	}
	for _, c := range s.clients {
		writeMsg(c, msgData, data)
	}
	s.mu.Unlock()
}

// runTCPBroker listens on a TCP port and manages multiple sessions.
// Each session has its own PTY. Sessions are identified by name via msgSession handshake.
func runTCPBroker(listenAddr, command string, extraArgs []string, cols, rows uint16) {
	signal.Ignore(syscall.SIGHUP)

	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "tcplisten: %v\n", err)
		os.Exit(1)
	}

	var mu sync.Mutex
	sessions := make(map[string]*tcpSession)

	logf := func(format string, args ...interface{}) {
		f, _ := os.OpenFile("/tmp/belve-persist-broker.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if f != nil {
			fmt.Fprintf(f, "%s "+format+"\n", append([]interface{}{time.Now().Format(time.RFC3339)}, args...)...)
			f.Close()
		}
	}

	logf("broker started on %s", listenAddr)

	getOrCreateSession := func(name string, initCols, initRows uint16, extraEnv []string) *tcpSession {
		mu.Lock()
		defer mu.Unlock()
		if s, ok := sessions[name]; ok && s.alive {
			return s
		}
		// Use client-provided size, fallback to broker defaults
		c, r := initCols, initRows
		if c == 0 {
			c = cols
		}
		if r == 0 {
			r = rows
		}
		// Create new session
		s := &tcpSession{
			name:     name,
			command:  command,
			args:     extraArgs,
			cols:     c,
			rows:     r,
			extraEnv: extraEnv,
			alive:    true,
		}
		sessions[name] = s
		go runSessionPTY(s, logf)
		return s
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			logf("accept error: %v", err)
			break
		}
		// PTY 1 byte write が頻発するので NoDelay 明示。
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
		}

		go func(c net.Conn) {
			// Read session handshake (name + \0 + cols:2 + rows:2)
			t, payload, err := readMsg(c)
			if err != nil || t != msgSession {
				logf("bad handshake from %s: type=%d err=%v", c.RemoteAddr(), t, err)
				c.Close()
				return
			}
			// Parse session name, optional initial size, and optional env list.
			// Format: name \0 cols:2 rows:2 [KEY=VAL \0 KEY=VAL \0 ...]
			var name string
			var initCols, initRows uint16
			var extraEnv []string
			if idx := bytes.IndexByte(payload, 0); idx >= 0 && len(payload) >= idx+5 {
				name = string(payload[:idx])
				initCols = binary.BigEndian.Uint16(payload[idx+1 : idx+3])
				initRows = binary.BigEndian.Uint16(payload[idx+3 : idx+5])
				if len(payload) > idx+5 {
					for _, entry := range bytes.Split(payload[idx+5:], []byte{0}) {
						if len(entry) > 0 {
							extraEnv = append(extraEnv, string(entry))
						}
					}
				}
			} else {
				name = string(payload)
			}
			logf("client connected: session=%s cols=%d rows=%d env=%d from=%s",
				name, initCols, initRows, len(extraEnv), c.RemoteAddr())

			sess := getOrCreateSession(name, initCols, initRows, extraEnv)
			sess.addClient(c)
			defer func() {
				sess.removeClient(c)
				c.Close()
				logf("client disconnected: session=%s from=%s", name, c.RemoteAddr())
			}()

			// Read from client → PTY
			for {
				t, payload, err := readMsg(c)
				if err != nil {
					break
				}
				switch t {
				case msgData:
					sess.mu.Lock()
					pf := sess.ptyFile
					sess.mu.Unlock()
					if pf != nil {
						pf.Write(payload)
					}
				case msgResize:
					if len(payload) == 4 {
						newCols := binary.BigEndian.Uint16(payload[0:2])
						newRows := binary.BigEndian.Uint16(payload[2:4])
						logf("session %s: resize cols=%d rows=%d", name, newCols, newRows)
						sess.mu.Lock()
						if sess.ptyFd != 0 {
							setPtySize(sess.ptyFd, newCols, newRows)
						}
						sess.cols = newCols
						sess.rows = newRows
						cPid := sess.childPid
						sess.mu.Unlock()
						// Send SIGWINCH to child process group
						if cPid > 0 {
							syscall.Kill(-cPid, syscall.SIGWINCH)
						}
					}
				}
			}
		}(conn)
	}
}

// runSessionPTY manages the PTY lifecycle for a TCP broker session.
// Respawns on SIGKILL (exit 137), exits on normal termination.
func runSessionPTY(s *tcpSession, logf func(string, ...interface{})) {
	const maxRespawns = 10
	respawnCount := 0

	for {
		ptyFile, ttyPath, err := openPTY()
		if err != nil {
			logf("session %s: openpty error: %v", s.name, err)
			s.mu.Lock()
			s.alive = false
			s.mu.Unlock()
			return
		}
		if s.cols > 0 && s.rows > 0 {
			setPtySize(ptyFile.Fd(), s.cols, s.rows)
		}
		ttyFile, err := os.OpenFile(ttyPath, os.O_RDWR, 0)
		if err != nil {
			logf("session %s: open tty error: %v", s.name, err)
			s.mu.Lock()
			s.alive = false
			s.mu.Unlock()
			return
		}

		var cmd *exec.Cmd
		if len(s.args) == 0 {
			cmd = exec.Command("/bin/sh", "-c", s.command)
		} else {
			cmd = exec.Command(s.command, s.args...)
		}
		cmd.Stdin = ttyFile
		cmd.Stdout = ttyFile
		cmd.Stderr = ttyFile
		cmd.SysProcAttr = setSysProcAttr(ttyFile)
		// Merge broker env with per-session env from handshake (BELVE_PANE_ID, etc).
		// Session values override broker-level values.
		env := os.Environ()
		if len(s.extraEnv) > 0 {
			overrides := map[string]bool{}
			for _, kv := range s.extraEnv {
				if eq := strings.IndexByte(kv, '='); eq > 0 {
					overrides[kv[:eq]] = true
				}
			}
			filtered := env[:0]
			for _, e := range env {
				if eq := strings.IndexByte(e, '='); eq > 0 && overrides[e[:eq]] {
					continue
				}
				filtered = append(filtered, e)
			}
			env = append(filtered, s.extraEnv...)
		}
		cmd.Env = env
		if err := cmd.Start(); err != nil {
			logf("session %s: exec error: %v", s.name, err)
			ttyFile.Close()
			s.mu.Lock()
			s.alive = false
			s.mu.Unlock()
			return
		}
		pid := cmd.Process.Pid
		ttyFile.Close()

		s.mu.Lock()
		s.ptyFile = ptyFile
		s.ptyFd = ptyFile.Fd()
		s.childPid = pid
		s.mu.Unlock()

		logf("session %s: child started pid=%d", s.name, pid)

		// PTY reader → broadcast (with coalesce: batch small chunks within 5ms)
		ptyDone := make(chan struct{})
		readerDone := make(chan struct{})
		dataCh := make(chan []byte, 64)

		// Goroutine A: read PTY, send chunks to channel
		go func() {
			defer close(readerDone)
			buf := make([]byte, 32*1024)
			for {
				n, err := ptyFile.Read(buf)
				if n > 0 {
					logf("session %s: pty-read n=%d", s.name, n)
					data := make([]byte, n)
					copy(data, buf[:n])
					dataCh <- data
				}
				if err != nil {
					return
				}
			}
		}()

		// Goroutine B: coalesce chunks and broadcast
		go func() {
			defer close(ptyDone)
			const coalesceWindow = 5 * time.Millisecond
			const maxAccumSize = 32 * 1024
			var accum []byte
			flush := func() {
				if len(accum) > 0 {
					logf("session %s: broadcast n=%d", s.name, len(accum))
					s.broadcast(accum)
					accum = nil
				}
			}
			for {
				if len(accum) == 0 {
					// Wait for first chunk (blocking)
					data, ok := <-dataCh
					if !ok {
						flush()
						return
					}
					accum = append(accum, data...)
				}
				// Have at least one chunk; try to coalesce more
				timer := time.NewTimer(coalesceWindow)
				coalescing := true
				for coalescing {
					select {
					case data, ok := <-dataCh:
						if !ok {
							timer.Stop()
							flush()
							return
						}
						accum = append(accum, data...)
						if len(accum) >= maxAccumSize {
							timer.Stop()
							coalescing = false
						}
					case <-timer.C:
						coalescing = false
					}
				}
				flush()
			}
		}()

		// Wait for reader to finish, then close channel to signal coalescer
		go func() {
			<-readerDone
			close(dataCh)
		}()

		waitErr := cmd.Wait()
		<-ptyDone
		ptyFile.Close()

		s.mu.Lock()
		s.ptyFile = nil
		s.ptyFd = 0
		s.mu.Unlock()

		exitCode := 0
		if exitErr, ok := waitErr.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		}
		logf("session %s: child exited pid=%d code=%d", s.name, pid, exitCode)

		// Respawn on SIGKILL
		if exitCode == 137 && respawnCount < maxRespawns {
			respawnCount++
			statusMessage := "Remote terminal crashed (exit 137). Restarting shell..."
			msg := fmt.Sprintf("\r\n\x1b[33m[belve] remote terminal crashed (exit 137), restarting shell... (%d/%d)\x1b[0m\r\n",
				respawnCount, maxRespawns)
			notice := belveNoticeData(statusMessage, msg)
			s.mu.Lock()
			s.replayBuf = nil
			for _, c := range s.clients {
				writeMsg(c, msgData, notice)
			}
			s.mu.Unlock()
			time.Sleep(500 * time.Millisecond)
			continue
		}

		// Normal exit — mark session as dead
		s.mu.Lock()
		s.alive = false
		s.mu.Unlock()
		break
	}
}

// --- TCP backend (host side) ---

// runMasterTCPBackend runs a host persist daemon that bridges Unix socket clients
// to a TCP broker in the container. No child process or PTY needed on the host side.
func runMasterTCPBackend(socketPath, tcpAddr, sessName, routeProjShort string, cols, rows uint16) {
	// Always kill old daemons for this socket, then take over.
	killOldDaemons(socketPath)
	os.Remove(socketPath)
	writePidFile(socketPath)

	signal.Ignore(syscall.SIGHUP)

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(1)
	}

	var mu sync.Mutex
	var clients []net.Conn
	var replayBuf []byte
	const replayMax = 4 * 1024 * 1024

	addClient := func(c net.Conn) {
		mu.Lock()
		if len(replayBuf) > 0 {
			writeReplayChunks(c, replayBuf)
		}
		clients = append(clients, c)
		mu.Unlock()
	}
	removeClient := func(c net.Conn) {
		mu.Lock()
		for i, cl := range clients {
			if cl == c {
				clients = append(clients[:i], clients[i+1:]...)
				break
			}
		}
		mu.Unlock()
	}

	// Forward from Unix socket client → TCP (will be set when TCP connects)
	var tcpConn net.Conn
	var tcpMu sync.Mutex

	sendToTCP := func(msgType byte, data []byte) {
		tcpMu.Lock()
		tc := tcpConn
		if tc != nil {
			writeMsg(tc, msgType, data)
		}
		tcpMu.Unlock()
	}

	logf := func(format string, args ...interface{}) {
		f, _ := os.OpenFile("/tmp/belve-persist-tcpbackend.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if f != nil {
			fmt.Fprintf(f, "%s "+format+"\n", append([]interface{}{time.Now().Format(time.RFC3339)}, args...)...)
			f.Close()
		}
	}

	// Accept Unix socket clients (from SSH attach)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				break
			}
			addClient(conn)
			go func(c net.Conn) {
				defer func() {
					removeClient(c)
					c.Close()
				}()
				for {
					t, payload, err := readMsg(c)
					if err != nil {
						break
					}
					switch t {
					case msgData:
						sendToTCP(msgData, payload)
					case msgResize:
						if len(payload) == 4 {
							newCols := binary.BigEndian.Uint16(payload[0:2])
							newRows := binary.BigEndian.Uint16(payload[2:4])
							logf("resize from client: cols=%d rows=%d", newCols, newRows)
							mu.Lock()
							cols = newCols
							rows = newRows
							mu.Unlock()
						}
						sendToTCP(msgResize, payload)
					}
				}
			}(conn)
		}
	}()

	// TCP connect/reconnect loop
	const maxReconnects = 100
	reconnectStatus, reconnectText := classifyReconnectStatus(nil)
	for attempt := 0; attempt < maxReconnects; attempt++ {
		if attempt > 0 {
			msg := fmt.Sprintf("%s (%d/%d)\r\n", strings.TrimRight(reconnectText, "\r\n"),
				attempt, maxReconnects)
			notice := belveNoticeData(reconnectStatus, msg)
			mu.Lock()
			for _, c := range clients {
				writeMsg(c, msgData, notice)
			}
			mu.Unlock()
			time.Sleep(2 * time.Second)
		}

		conn, err := net.DialTimeout("tcp", tcpAddr, 5*time.Second)
		if err != nil {
			logf("tcp connect failed: %v (attempt %d)", err, attempt+1)
			continue
		}
		// PTY は 1 byte 単位の write が多いので Nagle を明示的に切る
		// (Go default は true だが念のため)。
		if tc, ok := conn.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
		}

		// Phase B router preamble. routeProjShort が指定されてれば、
		// MSG_INIT より前に NDJSON 1 行で routing 情報を送る。
		// router 未経由 (= 直接 broker に繋ぐレガシー経路) の時は空文字、
		// この場合 preamble は送らない。
		if routeProjShort != "" {
			pre := fmt.Sprintf("{\"projShort\":%q,\"kind\":\"pty\"}\n", routeProjShort)
			if _, err := conn.Write([]byte(pre)); err != nil {
				logf("router preamble write failed: %v", err)
				conn.Close()
				continue
			}
		}

		// Send session handshake:
		//   name \0 cols:2 rows:2 [KEY=VAL \0 ...]
		// Forward BELVE_* env vars so the broker can apply them to the per-session
		// shell (needed for claude-hook OSC notifications that reference BELVE_PANE_ID).
		mu.Lock()
		sessionPayload := append([]byte(sessName), 0)
		szBuf := make([]byte, 4)
		binary.BigEndian.PutUint16(szBuf[0:2], cols)
		binary.BigEndian.PutUint16(szBuf[2:4], rows)
		sessionPayload = append(sessionPayload, szBuf...)
		for _, kv := range os.Environ() {
			if strings.HasPrefix(kv, "BELVE_") {
				sessionPayload = append(sessionPayload, []byte(kv)...)
				sessionPayload = append(sessionPayload, 0)
			}
		}
		mu.Unlock()
		if err := writeMsg(conn, msgSession, sessionPayload); err != nil {
			logf("session handshake failed: %v", err)
			conn.Close()
			continue
		}

		tcpMu.Lock()
		tcpConn = conn
		tcpMu.Unlock()

		logf("tcp connected to %s session=%s", tcpAddr, sessName)

		// Read from TCP → broadcast to Unix socket clients
		func() {
			defer func() {
				tcpMu.Lock()
				tcpConn = nil
				tcpMu.Unlock()
				conn.Close()
			}()
			for {
				t, data, err := readMsg(conn)
				if err != nil {
					logf("tcp read error: %v", err)
					reconnectStatus, reconnectText = classifyReconnectStatus(err)
					return
				}
				if t == msgData {
					mu.Lock()
					replayBuf = append(replayBuf, data...)
					if len(replayBuf) > replayMax {
						replayBuf = replayBuf[len(replayBuf)-replayMax:]
					}
					for _, c := range clients {
						writeMsg(c, msgData, data)
					}
					mu.Unlock()
				}
			}
		}()

		// TCP disconnected — loop back and reconnect
		logf("tcp disconnected, will reconnect")
		if reconnectStatus == "" {
			reconnectStatus, reconnectText = classifyReconnectStatus(nil)
		}
	}

	logf("max reconnects exhausted, exiting")
	listener.Close()
}

// spawnDaemon starts the master as a background process.
// spawnTCPBackendDaemon: tcpbackend mode の self-fork。Mac launcher の `nohup ... &`
// 相当を Go で内蔵化 (Phase 4)。fork 後 cmd.Process.Release で完全 detach。
func spawnTCPBackendDaemon(socketPath, tcpAddr, sessName, routeProjShort string, cols, rows int) {
	selfPath := os.Args[0]
	args := []string{selfPath,
		"-daemon",
		"-socket", socketPath,
		"-tcpbackend", tcpAddr,
		"-session", sessName,
	}
	if routeProjShort != "" {
		args = append(args, "-route", routeProjShort)
	}
	if cols > 0 && rows > 0 {
		args = append(args, "-cols", fmt.Sprintf("%d", cols), "-rows", fmt.Sprintf("%d", rows))
	}
	cmd := exec.Command(args[0], args[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "tcpbackend daemon spawn: %v\n", err)
		os.Exit(1)
	}
	cmd.Process.Release()
}

func spawnDaemon(socketPath string, cmdArgs []string, cols, rows int) {
	selfPath := os.Args[0]
	// Use -daemon flag to run master directly
	daemonArgs := []string{selfPath, "-daemon", "-socket", socketPath}
	if cols > 0 && rows > 0 {
		daemonArgs = append(daemonArgs, "-cols", fmt.Sprintf("%d", cols), "-rows", fmt.Sprintf("%d", rows))
	}
	daemonArgs = append(daemonArgs, "-command", cmdArgs[0])
	if len(cmdArgs) > 1 {
		daemonArgs = append(daemonArgs, "--")
		daemonArgs = append(daemonArgs, cmdArgs[1:]...)
	}

	cmd := exec.Command(daemonArgs[0], daemonArgs[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	cmd.Env = os.Environ()

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "daemon: %v\n", err)
		os.Exit(1)
	}
	cmd.Process.Release()
}

func tryAttach(socketPath string) bool {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return false
	}
	defer conn.Close()

	fd := int(os.Stdin.Fd())
	oldState, rawErr := setRawTerminal(fd)
	if rawErr == nil {
		defer restoreTerminal(fd, oldState)
	}

	if cols, rows, err := getTerminalSize(fd); err == nil {
		payload := make([]byte, 4)
		binary.BigEndian.PutUint16(payload[0:2], cols)
		binary.BigEndian.PutUint16(payload[2:4], rows)
		writeMsg(conn, msgResize, payload)
	}

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGWINCH)
	go func() {
		for range sigCh {
			if cols, rows, err := getTerminalSize(fd); err == nil {
				payload := make([]byte, 4)
				binary.BigEndian.PutUint16(payload[0:2], cols)
				binary.BigEndian.PutUint16(payload[2:4], rows)
				writeMsg(conn, msgResize, payload)
			}
		}
	}()

	done := make(chan struct{}, 1)

	logExit := func(reason string) {
		f, _ := os.OpenFile("/tmp/belve-persist-client.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
		if f != nil {
			fmt.Fprintf(f, "%s client exit: socket=%s reason=%s\n", time.Now().Format(time.RFC3339), socketPath, reason)
			f.Close()
		}
	}

	go func() {
		for {
			t, payload, err := readMsg(conn)
			if err != nil {
				logExit("socket-read: " + err.Error())
				break
			}
			if t == msgData {
				os.Stdout.Write(payload)
			}
		}
		done <- struct{}{}
	}()

	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				writeMsg(conn, msgData, buf[:n])
			}
			if err != nil {
				logExit("stdin-read: " + err.Error())
				break
			}
		}
		done <- struct{}{}
	}()

	<-done
	return true
}

func writeMsg(w io.Writer, msgType byte, data []byte) error {
	// Single write to prevent interleaving when multiple goroutines
	// write to the same connection concurrently.
	buf := make([]byte, 5+len(data))
	buf[0] = msgType
	binary.BigEndian.PutUint32(buf[1:5], uint32(len(data)))
	copy(buf[5:], data)
	_, err := w.Write(buf)
	return err
}

func belveStatusData(message string) []byte {
	if message == "" {
		return nil
	}
	return []byte(fmt.Sprintf("\x1b]9;belve-status;%s\x07", message))
}

func belveNoticeData(statusMessage, visibleMessage string) []byte {
	status := belveStatusData(statusMessage)
	if visibleMessage == "" {
		return status
	}
	if len(status) == 0 {
		return []byte(visibleMessage)
	}
	data := make([]byte, 0, len(status)+len(visibleMessage))
	data = append(data, status...)
	data = append(data, visibleMessage...)
	return data
}

func classifyReconnectStatus(err error) (string, string) {
	if err != nil && strings.Contains(err.Error(), "message too large") {
		return "Terminal transport desynced. Recreating backend connection...",
			"\r\n\x1b[33m[belve] terminal transport desynced; recreating backend connection...\x1b[0m\r\n"
	}
	return "Connection to container lost. Reconnecting...",
		"\r\n\x1b[33m[belve] connection to container lost, reconnecting...\x1b[0m\r\n"
}

// Maximum payload size per framed message. Must be ≥ replay-buffer chunk size
// (see `replayChunkSize`). Larger than `replayChunkSize` gives protocol
// headroom for future growth without another desync loop.
const maxMsgSize = 16 * 1024 * 1024

// Split replay buffer writes into chunks so a single replay message never
// exceeds the protocol limit. 512 KiB keeps us safely below `maxMsgSize` and
// under any realistic TCP/TLS buffer pressure.
const replayChunkSize = 512 * 1024

// writeReplayChunks sends `buf` to `c` as one or more `msgData` frames,
// chunking when the buffer is larger than `replayChunkSize`.
func writeReplayChunks(c net.Conn, buf []byte) {
	for start := 0; start < len(buf); start += replayChunkSize {
		end := start + replayChunkSize
		if end > len(buf) {
			end = len(buf)
		}
		writeMsg(c, msgData, buf[start:end])
	}
}

func readMsg(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:5])
	if length > maxMsgSize {
		return 0, nil, fmt.Errorf("message too large: %d", length)
	}
	payload := make([]byte, length)
	if length > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return 0, nil, err
		}
	}
	return header[0], payload, nil
}

// killOldDaemons finds and kills old belve-persist daemon processes (and their
// entire process trees) that reference the same socket path. This prevents
// process accumulation when daemons restart after child SIGKILL or socket staleness.
// killOldDaemons kills any existing daemon for this socket using a PID file,
// then falls back to /proc scan. Works on both Linux and macOS.
func killOldDaemons(socketPath string) {
	pidFile := socketPath + ".pid"
	myPid := os.Getpid()

	// 1. Try PID file
	if data, err := os.ReadFile(pidFile); err == nil {
		var oldPid int
		if _, err := fmt.Sscanf(string(data), "%d", &oldPid); err == nil && oldPid != myPid && oldPid > 0 {
			// Kill process tree
			killTree(oldPid)
		}
	}
	os.Remove(pidFile)

	// 2. Fallback: /proc scan (Linux only)
	if _, err := os.Stat("/proc/1"); err == nil {
		script := fmt.Sprintf(
			`mypid=%d; `+
				`for d in /proc/[0-9]*/cmdline; do `+
				`pid=${d#/proc/}; pid=${pid%%%%/cmdline}; `+
				`[ "$pid" = "$mypid" ] && continue; `+
				`tr '\0' ' ' < "$d" 2>/dev/null | grep -q 'belve-persist.*%s' || continue; `+
				`kill -9 "$pid" 2>/dev/null; `+
				`done`,
			myPid, socketPath)
		exec.Command("sh", "-c", script).Run()
	}

	// 3. Fallback: pkill (macOS)
	exec.Command("sh", "-c",
		fmt.Sprintf(`pgrep -f 'belve-persist.*%s' 2>/dev/null | while read pid; do [ "$pid" != "%d" ] && kill -9 "$pid" 2>/dev/null; done`,
			socketPath, myPid)).Run()
}

// killTree kills a process and all its children.
func killTree(pid int) {
	// Kill children first
	if out, err := exec.Command("pgrep", "-P", fmt.Sprintf("%d", pid)).Output(); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
			var childPid int
			if _, err := fmt.Sscanf(line, "%d", &childPid); err == nil && childPid > 0 {
				killTree(childPid)
			}
		}
	}
	syscall.Kill(pid, syscall.SIGKILL)
}

// writePidFile writes the current PID to a file associated with the socket.
func writePidFile(socketPath string) {
	pidFile := socketPath + ".pid"
	os.WriteFile(pidFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644)
}

// (Removed in Phase 5 cleanup: cleanupLocalProcesses, cleanupOldContainerProcesses,
// detectContainerID, detectContainerSocket, detectWorkdir, detectEnvValue,
// ensureContainerDaemon, resizeContainerPty — these were workarounds for the
// pre-Phase-B docker-exec broker architecture. The current container broker
// runs inside the container via runTCPBroker and resizes via setPtySize +
// sendSigwinchToPty (descendant-walking), so the docker-exec helpers are dead.)
