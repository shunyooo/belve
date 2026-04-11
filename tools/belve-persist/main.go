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

func runMaster(socketPath, command string, args []string, cols, rows uint16) {
	os.Remove(socketPath)

	// Ignore SIGHUP to survive SSH/docker disconnects
	signal.Ignore(syscall.SIGHUP)

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
	const replayMax = 256 * 1024 // ~2500 lines of terminal output
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
						}
					}
				}
			}(conn)
		}
	}()

	// Wait for child — daemon stays alive until child exits
	cmd.Wait()
	listener.Close()
	os.Remove(socketPath)
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

	go func() {
		for {
			t, payload, err := readMsg(conn)
			if err != nil {
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
