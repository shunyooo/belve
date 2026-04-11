package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

func openPTY() (masterFd uintptr, ttyPath string, err error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		return 0, "", fmt.Errorf("open /dev/ptmx: %w", err)
	}
	fd := master.Fd()

	// unlockpt
	var unlock int
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); errno != 0 {
		master.Close()
		return 0, "", fmt.Errorf("unlockpt: %w", errno)
	}

	// ptsname via TIOCGPTN
	var ptsNum uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, 0x80045430 /* TIOCGPTN */, uintptr(unsafe.Pointer(&ptsNum))); errno != 0 {
		master.Close()
		return 0, "", fmt.Errorf("ptsname: %w", errno)
	}

	slavePath := fmt.Sprintf("/dev/pts/%d", ptsNum)
	return fd, slavePath, nil
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
	}
}

func sendSigwinchToPty(fd uintptr) {
	// Try TIOCGPGRP first (foreground process group of PTY)
	var pgid int32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGPGRP, uintptr(unsafe.Pointer(&pgid)))
	if errno == 0 && pgid > 0 {
		syscall.Kill(-int(pgid), syscall.SIGWINCH)
		return
	}
	// Fallback: send to child process directly
	if childPid > 0 {
		syscall.Kill(childPid, syscall.SIGWINCH)
	}
}
