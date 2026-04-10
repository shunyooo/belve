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
)

const (
	msgData   byte = 0
	msgResize byte = 1
)

func main() {
	socketPath := flag.String("socket", "", "Unix socket path")
	command := flag.String("command", "", "command to run (creates session)")
	flag.Parse()

	if *socketPath == "" {
		fmt.Fprintln(os.Stderr, "usage: belve-persist -socket <path> [-command <cmd> [args...]]")
		os.Exit(1)
	}

	// Try attach to existing session
	if tryAttach(*socketPath) {
		return
	}

	if *command == "" {
		fmt.Fprintln(os.Stderr, "no existing session; specify -command to create one")
		os.Exit(1)
	}

	runMaster(*socketPath, *command, flag.Args())
}

func runMaster(socketPath, command string, args []string) {
	os.Remove(socketPath)

	// Ignore SIGHUP to survive SSH/docker disconnects
	signal.Ignore(syscall.SIGHUP)

	ptyFd, ttyPath, err := openPTY()
	if err != nil {
		fmt.Fprintf(os.Stderr, "openpty: %v\n", err)
		os.Exit(1)
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
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Env = os.Environ()
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "exec: %v\n", err)
		os.Exit(1)
	}
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

	// Auto-attach: stdin → PTY directly
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, err := os.Stdin.Read(buf)
			if n > 0 {
				ptyFile.Write(buf[:n])
			}
			if err != nil {
				break // stdin closed = SSH/docker disconnected
			}
		}
	}()

	// Set initial window size
	if cols, rows, err := getTerminalSize(int(os.Stdin.Fd())); err == nil {
		setPtySize(ptyFd, cols, rows)
	}

	// Handle SIGWINCH for auto-attach
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGWINCH)
	go func() {
		for range sigCh {
			if cols, rows, err := getTerminalSize(int(os.Stdin.Fd())); err == nil {
				setPtySize(ptyFd, cols, rows)
			}
		}
	}()

	// Wait for child — keeps master alive as daemon after disconnect
	cmd.Wait()
	os.Remove(socketPath)
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
