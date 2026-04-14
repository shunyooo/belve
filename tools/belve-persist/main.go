// belve-persist: minimal process persistence (dtach-like).
// Full PTY passthrough: no mouse/OSC interference.
//
// Create + attach: belve-persist -socket /path -command /bin/bash
// Attach only:     belve-persist -socket /path

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

const (
	msgData   byte = 0
	msgResize byte = 1
)

func main() {
	socketPath := flag.String("socket", "", "Unix socket path")
	command := flag.String("command", "", "command to run (creates session)")
	daemon := flag.Bool("daemon", false, "run as daemon master (internal)")
	initCols := flag.Int("cols", 0, "initial PTY columns")
	initRows := flag.Int("rows", 0, "initial PTY rows")
	flag.Parse()

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
		// Single command string: wrap in /bin/sh -c for compound commands (env vars, pipes, etc.)
		cmdArgs = []string{"/bin/sh", "-c", *command}
	} else {
		// Multi-arg command (e.g. docker exec -it ...): exec directly
		cmdArgs = append([]string{*command}, args...)
	}
	spawnDaemon(*socketPath, cmdArgs, *initCols, *initRows)

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

var containerID string
var containerPaneID string

func runMaster(socketPath, command string, args []string, cols, rows uint16) {
	// If another daemon is already listening, exit quietly (don't steal the socket)
	if conn, err := net.Dial("unix", socketPath); err == nil {
		conn.Close()
		return
	}
	os.Remove(socketPath) // only remove stale sockets

	// Detect container ID and pane ID from docker exec command args
	containerID = detectContainerID(command, args)
	containerPaneID = detectEnvValue(command, args, "BELVE_PANE_ID")

	// Ignore SIGHUP to survive SSH/docker disconnects
	signal.Ignore(syscall.SIGHUP)

	// No cleanup here — container persist sessions must survive across
	// docker exec restarts. Old sessions are naturally cleaned up when
	// tryAttach succeeds (reusing existing session) or when bash exits.

	ptyFd, ttyPath, err := openPTY()
	if err != nil {
		fmt.Fprintf(os.Stderr, "openpty: %v\n", err)
		os.Exit(1)
	}
	// Set initial PTY size before starting child
	if cols > 0 && rows > 0 {
		setPtySize(ptyFd, cols, rows)
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
	ptyFile := os.NewFile(ptyFd, "pty")

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen: %v\n", err)
		os.Exit(1)
	}

	var mu sync.Mutex
	var clients []net.Conn
	const replayMax = 64 * 1024 // ~800 lines of terminal output
	var replayBuf []byte

	addClient := func(c net.Conn) {
		mu.Lock()
		if len(replayBuf) > 0 {
			writeMsg(c, msgData, replayBuf)
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

	// PTY → broadcast + replay buffer
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := ptyFile.Read(buf)
			if n > 0 {
				data := make([]byte, n)
				copy(data, buf[:n])
				mu.Lock()
				replayBuf = append(replayBuf, data...)
				if len(replayBuf) > replayMax {
					replayBuf = replayBuf[len(replayBuf)-replayMax:]
				}
				for _, c := range clients {
					writeMsg(c, msgData, data)
				}
				mu.Unlock()

				// Also write to stdout for auto-attach
				os.Stdout.Write(data)
			}
			if err != nil {
				break
			}
		}
		listener.Close()
	}()

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
						ptyFile.Write(payload)
					case msgResize:
						if len(payload) == 4 {
							cols := binary.BigEndian.Uint16(payload[0:2])
							rows := binary.BigEndian.Uint16(payload[2:4])
							setPtySize(ptyFd, cols, rows)
							if containerID != "" {
								go resizeContainerPty(containerID, containerPaneID, cols, rows)
							}
							f, _ := os.OpenFile("/tmp/belve-persist-resize.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
							if f != nil {
								fmt.Fprintf(f, "%s resize: cols=%d rows=%d cid=%s pane=%s\n", time.Now().Format(time.RFC3339), cols, rows, containerID, containerPaneID)
								f.Close()
							}
						}
					}
				}
			}(conn)
		}
	}()

	// Monitor child health in background
	go func() {
		for {
			time.Sleep(5 * time.Second)
			if cmd.ProcessState != nil {
				return // already exited
			}
			// Check if child is still alive
			if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
				f, _ := os.OpenFile("/tmp/belve-persist-exit.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
				if f != nil {
					fmt.Fprintf(f, "%s child-check: pid=%d signal(0) err=%v (child may be dying)\n",
						time.Now().Format(time.RFC3339), childPid, err)
					f.Close()
				}
				return
			}
		}
	}()

	// Wait for child — daemon stays alive until child exits
	err = cmd.Wait()

	// Detailed exit diagnostics
	logFile, _ := os.OpenFile("/tmp/belve-persist-exit.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if logFile != nil {
		exitSignal := ""
		exitCode := -1
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
			if status, ok := exitErr.Sys().(syscall.WaitStatus); ok {
				if status.Signaled() {
					exitSignal = status.Signal().String()
				}
			}
		} else if err == nil {
			exitCode = 0
		}

		// Capture process tree snapshot
		procSnapshot := ""
		if out, snapErr := exec.Command("ps", "aux", "--sort=-start_time").Output(); snapErr == nil {
			lines := 0
			for _, b := range out {
				if b == '\n' { lines++ }
				if lines > 20 { break }
				procSnapshot += string(b)
			}
		}

		// Memory info
		memInfo := ""
		if out, memErr := exec.Command("sh", "-c", "cat /proc/meminfo 2>/dev/null | head -3").Output(); memErr == nil {
			memInfo = string(out)
		}

		fmt.Fprintf(logFile, "=== %s master exit ===\nsocket=%s childPid=%d err=%v exitCode=%d signal=%s\n--- memory ---\n%s--- top processes ---\n%s\n",
			time.Now().Format(time.RFC3339), socketPath, childPid, err, exitCode, exitSignal, memInfo, procSnapshot)
		logFile.Close()
	}
	listener.Close()
	// Don't remove socket — a new daemon may have already created one.
	// Stale sockets are cleaned up by runMaster's connection check on startup.
}

// spawnDaemon starts the master as a background process.
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
	header := [5]byte{msgType}
	binary.BigEndian.PutUint32(header[1:5], uint32(len(data)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	if len(data) > 0 {
		_, err := w.Write(data)
		return err
	}
	return nil
}

func readMsg(r io.Reader) (byte, []byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return 0, nil, err
	}
	length := binary.BigEndian.Uint32(header[1:5])
	if length > 1<<20 {
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

// cleanupLocalProcesses kills old local processes with the same pane ID.
// Used inside containers where there's no docker exec wrapper.
func cleanupLocalProcesses(paneID string) {
	// Kill old belve-persist daemons for the same session
	// (the socket will be re-created by us)
	cmd := exec.Command("sh", "-c",
		fmt.Sprintf(`for d in /proc/[0-9]*/environ; do
			pid=${d#/proc/}; pid=${pid%%%%/environ}
			grep -qz 'BELVE_PANE_ID=%s' "$d" 2>/dev/null || continue
			[ "$pid" = "$$" ] && continue
			kill -9 "$pid" 2>/dev/null
		done`, paneID))
	cmd.Run()
}

// cleanupOldContainerProcesses kills old container processes with the same pane ID.
// Called synchronously before starting a new session to prevent zombie accumulation.
// Uses SIGKILL and also kills child processes via process group.
func cleanupOldContainerProcesses(cid, paneID string) {
	// Fast path: kill via PID file, then fall back to /proc scan for stragglers
	script := fmt.Sprintf(
		`pidfile="$HOME/.belve/panes/%s.pid"; `+
			`if [ -f "$pidfile" ]; then `+
			`pid=$(cat "$pidfile"); `+
			`kill -9 -"$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; `+
			`rm -f "$pidfile"; `+
			`fi; `+
			`for d in /proc/[0-9]*/environ; do `+
			`pid=${d#/proc/}; pid=${pid%%/environ}; `+
			`grep -qz 'BELVE_PANE_ID=%s' "$d" 2>/dev/null || continue; `+
			`kill -9 -"$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; `+
			`done`,
		paneID, paneID)
	cmd := exec.Command("docker", "exec", cid, "sh", "-c", script)
	cmd.Run()
}

// detectContainerID extracts the container ID from docker exec command args.
// Finds the first argument that is 12+ hex characters (container ID format).
func detectContainerID(command string, args []string) string {
	allArgs := append([]string{command}, args...)
	for _, arg := range allArgs {
		if len(arg) < 12 {
			continue
		}
		isHex := true
		for _, c := range arg {
			if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
				isHex = false
				break
			}
		}
		if isHex {
			return arg
		}
	}
	return ""
}

// detectEnvValue extracts the value of a -e KEY=VALUE arg from docker exec command args.
func detectEnvValue(command string, args []string, key string) string {
	allArgs := append([]string{command}, args...)
	prefix := key + "="
	for i, arg := range allArgs {
		if arg == "-e" && i+1 < len(allArgs) {
			if len(allArgs[i+1]) > len(prefix) && allArgs[i+1][:len(prefix)] == prefix {
				return allArgs[i+1][len(prefix):]
			}
		}
	}
	return ""
}

// resizeContainerPty resizes the PTY inside a Docker container by
// running stty via docker exec. This bypasses the docker exec SIGWINCH issue.
// When paneID is set, only the process with matching BELVE_PANE_ID is resized.
func resizeContainerPty(cid, paneID string, cols, rows uint16) {
	var script string
	if paneID != "" {
		// Fast path: use PID file written by session-bootstrap.sh
		// After stty, send SIGWINCH to the process and its group (for 2-layer persist)
		script = fmt.Sprintf(
			`pidfile="$HOME/.belve/panes/%s.pid"; `+
				`if [ -f "$pidfile" ]; then `+
				`pid=$(cat "$pidfile"); `+
				`tty=$(readlink /proc/$pid/fd/0 2>/dev/null); `+
				`if [ -n "$tty" ]; then stty -F "$tty" rows %d cols %d 2>/dev/null; kill -WINCH "$pid" 2>/dev/null; pkill -WINCH -P "$pid" 2>/dev/null; pkill -WINCH -P $(pgrep -P "$pid" | head -1) 2>/dev/null; exit 0; fi; `+
				`fi; `+
				`best=""; besttty=""; `+
				`for d in /proc/[0-9]*/environ; do `+
				`pid=${d#/proc/}; pid=${pid%%/environ}; `+
				`grep -qz 'BELVE_PANE_ID=%s' "$d" 2>/dev/null || continue; `+
				`tty=$(readlink /proc/$pid/fd/0 2>/dev/null); `+
				`echo "$tty" | grep -q "^/dev/pts/" || continue; `+
				`if [ -z "$best" ] || [ "$pid" -gt "$best" ]; then best=$pid; besttty=$tty; fi; `+
				`done; `+
				`[ -n "$besttty" ] && stty -F "$besttty" rows %d cols %d 2>/dev/null`,
			paneID, rows, cols, paneID, rows, cols)
	} else {
		// Fallback: resize the 4 newest belve-bashrc processes
		script = fmt.Sprintf(
			"for p in $(ps aux --sort=-start_time | grep belve-bashrc | grep -v grep | head -4 | awk '{print $2}'); "+
				"do TTY=$(readlink /proc/$p/fd/0 2>/dev/null) && [ -n \"$TTY\" ] && "+
				"stty -F $TTY rows %d cols %d 2>/dev/null; done",
			rows, cols)
	}
	cmd := exec.Command("docker", "exec", cid, "sh", "-c", script)
	cmd.Run()
}
