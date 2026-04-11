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

	// grantpt
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYGRANT, 0); errno != 0 {
		master.Close()
		return 0, "", fmt.Errorf("grantpt: %w", errno)
	}

	// unlockpt
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYUNLK, 0); errno != 0 {
		master.Close()
		return 0, "", fmt.Errorf("unlockpt: %w", errno)
	}

	// ptsname
	slaveName := make([]byte, 128)
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCPTYGNAME, uintptr(unsafe.Pointer(&slaveName[0]))); errno != 0 {
		master.Close()
		return 0, "", fmt.Errorf("ptsname: %w", errno)
	}

	slaveNameStr := ""
	for _, b := range slaveName {
		if b == 0 {
			break
		}
		slaveNameStr += string(b)
	}

	return fd, slaveNameStr, nil
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
	var pgid int32
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCGPGRP, uintptr(unsafe.Pointer(&pgid)))
	if errno == 0 && pgid > 0 {
		syscall.Kill(-int(pgid), syscall.SIGWINCH)
		return
	}
	if childPid > 0 {
		syscall.Kill(childPid, syscall.SIGWINCH)
	}
}
