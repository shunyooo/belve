package main

// SSH tunnel management。Belve.app の `SSHTunnelManager.swift` から移植。
//
// Mac 側の Swift コードがやってた事:
//   - host あたり 1 個の SSH ControlMaster を spawn して維持
//   - per-VM router への port forward を 1 個確立
//   - app 終了時に teardown
//
// これを master daemon に移すメリット:
//   - master は Belve.app 死亡後も生き続けるので、tunnel が壊れない
//   - tunnel state を全部 Go 側に集約 (ポート allocation も含めて)
//   - Belve.app は IPC で「使う local port を教えて」と聞くだけ

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	tunnelBasePort = 19222
	tunnelMaxPort  = 19322
)

type tunnelManager struct {
	mu               sync.Mutex
	allocatedPorts   map[int]bool   // 全 host にまたがる Mac ローカル port の重複防止
	routerForwards   map[string]int // host → local port (per-VM router forward)
	routerSpecs      map[string]string
	mastersSpawning  map[string]chan struct{} // host → spawn 完了通知 (dedupe)
	forwardsSpawning map[string]chan struct{} // host → forward 完了通知 (dedupe)
}

var globalTunnelManager = &tunnelManager{
	allocatedPorts:   map[int]bool{},
	routerForwards:   map[string]int{},
	routerSpecs:      map[string]string{},
	mastersSpawning:  map[string]chan struct{}{},
	forwardsSpawning: map[string]chan struct{}{},
}

// ensureRouterForward: host あたり 1 個の per-VM router 用 forward を保証する。
// 既にあれば即返却、無ければ ControlMaster + forward を確立して新規 port を返す。
func (tm *tunnelManager) ensureRouterForward(host string, remotePort int) (int, error) {
	if remotePort == 0 {
		remotePort = 19200
	}
	tm.mu.Lock()
	if p, ok := tm.routerForwards[host]; ok {
		tm.mu.Unlock()
		return p, nil
	}
	// in-flight な spawn があれば待つ
	if ch, ok := tm.forwardsSpawning[host]; ok {
		tm.mu.Unlock()
		<-ch
		tm.mu.Lock()
		if p, ok := tm.routerForwards[host]; ok {
			tm.mu.Unlock()
			return p, nil
		}
		tm.mu.Unlock()
		return 0, fmt.Errorf("forward spawn for %s failed", host)
	}
	done := make(chan struct{})
	tm.forwardsSpawning[host] = done
	tm.mu.Unlock()
	defer func() {
		tm.mu.Lock()
		delete(tm.forwardsSpawning, host)
		tm.mu.Unlock()
		close(done)
	}()

	// 1) ControlMaster
	if err := tm.ensureControlMaster(host); err != nil {
		return 0, fmt.Errorf("control master: %w", err)
	}

	// 2) port allocation
	port, err := tm.allocateLocalPort()
	if err != nil {
		return 0, err
	}

	// 3) ssh -O forward
	spec := fmt.Sprintf("%d:127.0.0.1:%d", port, remotePort)
	args := []string{
		"-o", "ControlPath=" + sshControlPath(host),
		"-O", "forward",
		"-L", spec,
		host,
	}
	c := exec.Command("ssh", args...)
	if out, err := c.CombinedOutput(); err != nil {
		// release port
		tm.mu.Lock()
		delete(tm.allocatedPorts, port)
		tm.mu.Unlock()
		return 0, fmt.Errorf("ssh -O forward: %v: %s", err, out)
	}

	tm.mu.Lock()
	tm.routerForwards[host] = port
	tm.routerSpecs[host] = spec
	tm.mu.Unlock()
	fmt.Fprintf(os.Stderr, "[belve-master] router forward host=%s local=%d -> 127.0.0.1:%d\n", host, port, remotePort)
	return port, nil
}

func (tm *tunnelManager) allocateLocalPort() (int, error) {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	for port := tunnelBasePort; port <= tunnelMaxPort; port++ {
		if tm.allocatedPorts[port] {
			continue
		}
		if !isPortFreeMac(port) {
			continue
		}
		tm.allocatedPorts[port] = true
		return port, nil
	}
	return 0, fmt.Errorf("no port available in %d..%d", tunnelBasePort, tunnelMaxPort)
}

func isPortFreeMac(port int) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return false
	}
	l.Close()
	return true
}

// ensureControlMaster: host への SSH master を spawn (なければ)。
// in-flight dedupe + check で既存判定。
func (tm *tunnelManager) ensureControlMaster(host string) error {
	if tm.checkMaster(host) {
		return nil
	}
	tm.mu.Lock()
	if ch, ok := tm.mastersSpawning[host]; ok {
		tm.mu.Unlock()
		<-ch
		if tm.checkMaster(host) {
			return nil
		}
		return fmt.Errorf("master spawn for %s failed", host)
	}
	done := make(chan struct{})
	tm.mastersSpawning[host] = done
	tm.mu.Unlock()
	defer func() {
		tm.mu.Lock()
		delete(tm.mastersSpawning, host)
		tm.mu.Unlock()
		close(done)
	}()

	args := []string{
		"-o", "ControlMaster=yes",
		"-o", "ControlPath=" + sshControlPath(host),
		"-o", "ControlPersist=600",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
		"-fN",
		host,
	}
	c := exec.Command("ssh", args...)
	if err := c.Run(); err != nil {
		return fmt.Errorf("ssh -fN: %w", err)
	}
	// Poll until master responds (~5s budget)
	for i := 0; i < 50; i++ {
		if tm.checkMaster(host) {
			fmt.Fprintf(os.Stderr, "[belve-master] ssh master up host=%s\n", host)
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("master spawn timeout host=%s", host)
}

func (tm *tunnelManager) checkMaster(host string) bool {
	args := []string{
		"-o", "ControlPath=" + sshControlPath(host),
		"-O", "check",
		host,
	}
	c := exec.Command("ssh", args...)
	return c.Run() == nil
}

// teardownAll: 全 forward を cancel + master を exit。app shutdown 時に呼ぶ
// (実際 master は app shutdown とは独立なので、明示的にしか呼ばれない想定)。
func (tm *tunnelManager) teardownAll() {
	tm.mu.Lock()
	routers := tm.routerForwards
	specs := tm.routerSpecs
	tm.routerForwards = map[string]int{}
	tm.routerSpecs = map[string]string{}
	tm.allocatedPorts = map[int]bool{}
	tm.mu.Unlock()

	for host := range routers {
		spec := specs[host]
		if spec != "" {
			args := []string{
				"-o", "ControlPath=" + sshControlPath(host),
				"-O", "cancel",
				"-L", spec,
				host,
			}
			_ = exec.Command("ssh", args...).Run()
		}
		// master 自体も exit
		args2 := []string{
			"-o", "ControlPath=" + sshControlPath(host),
			"-O", "exit",
			host,
		}
		_ = exec.Command("ssh", args2...).Run()
	}
	// /tmp/belve-ssh-ctrl-* の残骸も掃除
	if entries, err := filepath.Glob("/tmp/belve-ssh-ctrl-*"); err == nil {
		for _, e := range entries {
			os.Remove(e)
		}
	}
	fmt.Fprintf(os.Stderr, "[belve-master] tunnel teardownAll done\n")
}

// status: Belve.app から「いまどの host にどの port が forward されてるか」聞く時に使う。
func (tm *tunnelManager) status() map[string]int {
	tm.mu.Lock()
	defer tm.mu.Unlock()
	snapshot := make(map[string]int, len(tm.routerForwards))
	for k, v := range tm.routerForwards {
		snapshot[k] = v
	}
	return snapshot
}

// hostFromControlSocket: /tmp/belve-ssh-ctrl-<host> の path から host 名を抜く。
// 存在 check に使う (master が落ちる前に socket file が残ってる事もある)。
func hostFromControlSocket(path string) string {
	prefix := "/tmp/belve-ssh-ctrl-"
	if strings.HasPrefix(path, prefix) {
		return strings.TrimPrefix(path, prefix)
	}
	return ""
}
