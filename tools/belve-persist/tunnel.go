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
	"encoding/json"
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
	// per-host の forward port を永続化する file。Master 再起動後に同じ port を
	// 再利用することで、走り続けてる per-pane belve-persist daemon (= -tcpbackend
	// 127.0.0.1:PORT) の reconnect が成功するようにする (= 古い master が
	// allocate した port を新 master が忘れて別 port を allocate → daemon が
	// 古い port を叩き続ける、という 2026-04-27 の事故の対策)。
	tunnelStateFile = "/tmp/belve-master-state.json"
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

func init() {
	globalTunnelManager.loadState()
	go globalTunnelManager.healthCheckLoop()
}

// persistedTunnelState: tunnelStateFile に書き出す JSON shape。
// 必要なのは host → local port mapping だけ (forward の有無は起動時に
// `isLocalPortReachable` で確認し、生きてれば再 allocate 不要、死んでれば
// 同 port で `ensureRouterForwardOnPort` を呼ぶ)。
type persistedTunnelState struct {
	RouterForwards map[string]int `json:"routerForwards"`
}

// loadState: 起動時に過去の port 割当を読み込んで `routerForwards` を復元する。
// `ensureRouterForward` の fast path (already-mapped check) で再利用される。
// 死んでた forward は次の `ensureRouterForward` 呼び出し or healthCheckLoop で
// 同 port で復活する。
func (tm *tunnelManager) loadState() {
	data, err := os.ReadFile(tunnelStateFile)
	if err != nil {
		return // 初回起動 / state なし
	}
	var st persistedTunnelState
	if err := json.Unmarshal(data, &st); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] loadState parse error: %v\n", err)
		return
	}
	tm.mu.Lock()
	defer tm.mu.Unlock()
	for host, port := range st.RouterForwards {
		tm.routerForwards[host] = port
		tm.allocatedPorts[port] = true
	}
	fmt.Fprintf(os.Stderr, "[belve-master] loadState restored %d host port mappings\n", len(st.RouterForwards))
}

// saveStateLocked: tm.mu を握ってる前提で state を書き出す。
// `ensureRouterForward` 系の最後で呼ぶ。書き込み失敗はログするだけで継続
// (state file 無しでも master は動く)。
func (tm *tunnelManager) saveStateLocked() {
	st := persistedTunnelState{
		RouterForwards: make(map[string]int, len(tm.routerForwards)),
	}
	for host, port := range tm.routerForwards {
		st.RouterForwards[host] = port
	}
	data, err := json.Marshal(st)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] saveState marshal error: %v\n", err)
		return
	}
	tmpPath := tunnelStateFile + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] saveState write error: %v\n", err)
		return
	}
	if err := os.Rename(tmpPath, tunnelStateFile); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] saveState rename error: %v\n", err)
	}
}

// healthCheckLoop: SSH master の再起動 / OS sleep 復帰 etc で forward が死んだ時に
// 既存の belve-persist client の reconnect-loop を救うため、定期的に forward
// を verify して死んでたら re-establish する。
//
// belve-persist client は master IPC を持たないので、自分から「forward 復旧して」
// と頼めない。「local port に connect する」だけしかできず、master 側で勝手に
// 復旧してくれることに依存する。
func (tm *tunnelManager) healthCheckLoop() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		tm.mu.Lock()
		snapshot := make(map[string]int, len(tm.routerForwards))
		for k, v := range tm.routerForwards {
			snapshot[k] = v
		}
		tm.mu.Unlock()
		for host, port := range snapshot {
			if isLocalPortReachable(port) {
				continue
			}
			fmt.Fprintf(os.Stderr, "[belve-master] health-check: forward host=%s port=%d dead → re-establish\n", host, port)
			tm.mu.Lock()
			delete(tm.routerForwards, host)
			delete(tm.routerSpecs, host)
			delete(tm.allocatedPorts, port)
			tm.mu.Unlock()
			// 同じ port を再 allocate して同じ番号で復旧 (= 既存 client の retry が
			// 同 port を叩き続けるので、新 port になると arrival しない)。
			if _, err := tm.ensureRouterForwardOnPort(host, port, 19200); err != nil {
				fmt.Fprintf(os.Stderr, "[belve-master] health-check: re-establish failed host=%s: %v\n", host, err)
			}
		}
	}
}

// ensureRouterForwardOnPort: 特定 port 指定で forward を確立する。health check
// 復旧用。allocateLocalPort は使わず、指定 port が空いていればそれを使う。
func (tm *tunnelManager) ensureRouterForwardOnPort(host string, localPort, remotePort int) (int, error) {
	if !isPortFreeMac(localPort) {
		// 別プロセスが既に占有 → fallback で別 port を取って再 establish
		return tm.ensureRouterForward(host, remotePort)
	}
	if err := tm.ensureControlMaster(host); err != nil {
		return 0, err
	}
	spec := fmt.Sprintf("%d:127.0.0.1:%d", localPort, remotePort)
	args := []string{
		"-o", "ControlPath=" + sshControlPath(host),
		"-O", "forward",
		"-L", spec,
		host,
	}
	c := exec.Command("ssh", args...)
	if out, err := c.CombinedOutput(); err != nil {
		return 0, fmt.Errorf("ssh -O forward: %v: %s", err, out)
	}
	tm.mu.Lock()
	tm.routerForwards[host] = localPort
	tm.routerSpecs[host] = spec
	tm.allocatedPorts[localPort] = true
	tm.saveStateLocked()
	tm.mu.Unlock()
	fmt.Fprintf(os.Stderr, "[belve-master] router forward (recovered) host=%s local=%d -> 127.0.0.1:%d\n", host, localPort, remotePort)
	return localPort, nil
}

// isLocalPortReachable: 指定 local port に TCP 接続できるか。SSH forward が
// 生きてるかの quick health check 用。
func isLocalPortReachable(port int) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// ensureRouterForward: host あたり 1 個の per-VM router 用 forward を保証する。
// 既にあれば即返却、無ければ ControlMaster + forward を確立して新規 port を返す。
//
// 既存 entry は **必ず生存確認** してから返す。SSH master が再起動した等の理由で
// 実際の forward が死んでいても master daemon の state は残ってしまう、
// stale state バグへの保険。死んでたら再確立する。
func (tm *tunnelManager) ensureRouterForward(host string, remotePort int) (int, error) {
	if remotePort == 0 {
		remotePort = 19200
	}
	tm.mu.Lock()
	if p, ok := tm.routerForwards[host]; ok {
		tm.mu.Unlock()
		if isLocalPortReachable(p) {
			return p, nil
		}
		// stale: forward が死んでる。**同じ port** で再確立を試みる。
		// これが成功すれば走り続けてる per-pane belve-persist daemon
		// (= -tcpbackend 127.0.0.1:p で接続待ち) の reconnect が透過に成功する。
		// 失敗したら通常の allocate にフォールバック。
		fmt.Fprintf(os.Stderr, "[belve-master] router forward host=%s port=%d is stale, attempting same-port re-establish\n", host, p)
		if recovered, err := tm.ensureRouterForwardOnPort(host, p, remotePort); err == nil {
			return recovered, nil
		}
		tm.mu.Lock()
		delete(tm.routerForwards, host)
		delete(tm.routerSpecs, host)
		delete(tm.allocatedPorts, p)
		tm.mu.Unlock()
		tm.mu.Lock()
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
	tm.saveStateLocked()
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
	tm.saveStateLocked()
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
