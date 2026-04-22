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

	// grantpt
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYGRANT, 0); errno != 0 {
		master.Close()
		return nil, "", fmt.Errorf("grantpt: %w", errno)
	}

	// unlockpt
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYUNLK, 0); errno != 0 {
		master.Close()
		return nil, "", fmt.Errorf("unlockpt: %w", errno)
	}

	// ptsname
	slaveName := make([]byte, 128)
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYGNAME, uintptr(unsafe.Pointer(&slaveName[0]))); errno != 0 {
		master.Close()
		return nil, "", fmt.Errorf("ptsname: %w", errno)
	}

	slaveNameStr := ""
	for _, b := range slaveName {
		if b == 0 {
			break
		}
		slaveNameStr += string(b)
	}

	return master, slaveNameStr, nil
}

func setPtySize(fd uintptr, cols, rows uint16) {
	ws := struct{ rows, cols, xpixel, ypixel uint16 }{rows, cols, 0, 0}
	syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSWINSZ, uintptr(unsafe.Pointer(&ws)))
	sendSigwinchToPty(fd)
}

var childPid int

func setSysProcAttr(ttyFile *os.File) *syscall.SysProcAttr {
	return &syscall.SysProcAttr{
		Setsid: true,
	}
}

func sendSigwinchToPty(fd uintptr) {
	if childPid <= 0 {
		return
	}
	// shell (= childPid) と shell が spawn した foreground program (claude code
	// 等) は別 process group に入る (zsh -i は tcsetpgrp が ENOTTY で失敗しても
	// setpgid は呼ぶため)。1 個の pgid に SIGWINCH 送るだけだと TUI に届かないので、
	// childPid の descendant 全 PID に直接 SIGWINCH を送る。
	//
	// TIOCGPGRP は誰も tcsetpgrp を呼んでない (Setctty 無いので無理) ため
	// daemon process 自身の pgid を返してきて使えない。この罠は Linux 版にもある。
	for _, pid := range descendantPids(childPid) {
		syscall.Kill(pid, syscall.SIGWINCH)
	}
}

// descendantPids: target を root とした子孫プロセスの PID 全部 (target 自身も含む)。
// `ps -eo pid,ppid` の出力を parsing するシンプル実装。プロセス数百くらいまでなら十分速い。
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
