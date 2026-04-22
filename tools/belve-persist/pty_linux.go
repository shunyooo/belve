package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

func openPTY() (masterFile *os.File, ttyPath string, err error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		return nil, "", fmt.Errorf("open /dev/ptmx: %w", err)
	}
	fd := master.Fd()

	// unlockpt
	var unlock int
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		master.Close()
		return nil, "", fmt.Errorf("unlockpt: %w", errno)
	}

	// ptsname via TIOCGPTN
	var ptsNum uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, 0x80045430 /* TIOCGPTN */, uintptr(unsafe.Pointer(&ptsNum))); errno != 0 {
		master.Close()
		return nil, "", fmt.Errorf("ptsname: %w", errno)
	}

	slavePath := fmt.Sprintf("/dev/pts/%d", ptsNum)
	return master, slavePath, nil
}

func setPtySize(fd uintptr, cols, rows uint16) {
	ws := struct{ rows, cols, xpixel, ypixel uint16 }{rows, cols, 0, 0}
	syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
	// SETSID without controlling terminal means TIOCSWINSZ doesn't trigger SIGWINCH.
	// Send SIGWINCH to the foreground process group of the PTY.
	sendSigwinchToPty(fd)
}

var childPid int // set by runMaster after cmd.Start()

func setSysProcAttr(ttyFile *os.File) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Setsid: true,
		// Setctty requires CAP_SYS_ADMIN in non-privileged containers
		// (Go hardcodes TIOCSCTTY arg=1). bash shows "cannot set terminal
		// process group" but this is cosmetic — functionality is unaffected.
	}
}

func sendSigwinchToPty(fd uintptr) {
	if childPid <= 0 {
		return
	}
	// shell (= childPid) が起動した foreground program (claude code 等) は
	// 別 process group に入るケースがある (tcsetpgrp が ENOTTY で失敗しても
	// setpgid は呼ぶ shell が居る; 特に zsh -i)。1 個の pgid に SIGWINCH 送る
	// だけだと TUI に届かないので、childPid の descendant 全 PID に直接送る。
	//
	// 注意: TIOCGPGRP は誰も tcsetpgrp を呼んでない (Setctty 無いので無理)
	// と daemon process 自身の pgid を返してきて使えない。pty_darwin.go で
	// 解決済みの罠で、Linux 側でも shell 次第で潜在化していたので統一実装。
	for _, pid := range descendantPids(childPid) {
		syscall.Kill(pid, syscall.SIGWINCH)
	}
}

// descendantPids: target を root とした子孫プロセスの PID 全部 (target 自身も含む)。
// `ps -eo pid,ppid` を parsing するシンプル実装。
func descendantPids(target int) []int {
	out, err := exec.Command("ps", "-eo", "pid,ppid").Output()
	if err != nil {
		return []int{target}
	}
	children := map[int][]int{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, e1 := strconv.Atoi(fields[0])
		ppid, e2 := strconv.Atoi(fields[1])
		if e1 != nil || e2 != nil {
			continue
		}
		children[ppid] = append(children[ppid], pid)
	}
	result := []int{target}
	queue := []int{target}
	for len(queue) > 0 {
		p := queue[0]
		queue = queue[1:]
		for _, c := range children[p] {
			result = append(result, c)
			queue = append(queue, c)
		}
	}
	return result
}
