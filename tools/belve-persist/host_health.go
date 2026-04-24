package main

// Host (= SSH 接続先 VM) の reachability cache。
// VM ダウン / OOM / network 切断時に SSH ConnectTimeout が毎回 10s 食うのを避け、
// 失敗を 60s ほどキャッシュして同 host への subsequent op は ms で fast-fail する。
//
// 自動 probe / auto-recovery はしない (= ユーザーが Cmd+R / Retry ボタンで明示的に
// reset する設計)。Belve.app 側で `master.resetHostHealth(host)` を呼ぶと cache が
// 消えて、stale な SSH ControlMaster socket も `ssh -O exit` で掃除される。

import (
	"fmt"
	"os/exec"
	"sync"
	"time"
)

// 失敗から fast-fail を続ける期間。これ以降は cache 自動失効して次回試行で再 SSH。
// 60s は「VM 復旧 〜 ユーザーが気づくまで」の典型的な間隔よりやや短めで、
// VM 復旧後に勝手に試行されて 10s SSH timeout 食らう事故を最小化する。
const hostFailureCacheDuration = 60 * time.Second

type hostHealthState struct {
	failedAt    time.Time // zero = healthy
	lastError   string
}

type hostHealthMonitor struct {
	mu     sync.Mutex
	hosts  map[string]*hostHealthState
}

var globalHostHealth = &hostHealthMonitor{hosts: map[string]*hostHealthState{}}

func (m *hostHealthMonitor) get(host string) *hostHealthState {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.hosts[host]; ok {
		return s
	}
	s := &hostHealthState{}
	m.hosts[host] = s
	return s
}

// checkOrFail: ensureSetup 等の op 開始時に呼ぶ。host が unhealthy で cache 期間内なら
// 即 error を返す (= SSH を打たない)。期間切れなら cache を自動 clear して nil 返す。
func (m *hostHealthMonitor) checkOrFail(host string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.hosts[host]
	if !ok || s.failedAt.IsZero() {
		return nil
	}
	if time.Since(s.failedAt) >= hostFailureCacheDuration {
		// auto-expire: 次回 op で SSH 再試行
		s.failedAt = time.Time{}
		s.lastError = ""
		return nil
	}
	return fmt.Errorf("host %s marked unreachable %ds ago: %s",
		host, int(time.Since(s.failedAt).Seconds()), s.lastError)
}

// markFailed: SSH op 失敗時に呼ぶ。push event 発火は呼び元で行う
// (master conn を握ってないので)。第二戻り値は「初回失敗かどうか」(= push 必要か)。
func (m *hostHealthMonitor) markFailed(host string, errStr string) (firstFailure bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.hosts[host]
	if !ok {
		s = &hostHealthState{}
		m.hosts[host] = s
	}
	first := s.failedAt.IsZero()
	s.failedAt = time.Now()
	s.lastError = errStr
	return first
}

// markHealthy: SSH op 成功時に呼ぶ。VM 復旧した経路。
func (m *hostHealthMonitor) markHealthy(host string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.hosts[host]; ok {
		s.failedAt = time.Time{}
		s.lastError = ""
	}
}

// reset: 明示的に cache をクリアし、stale な SSH ControlMaster socket も掃除する。
// Cmd+R / Retry ボタンから呼ばれる経路。
func (m *hostHealthMonitor) reset(host string) {
	m.mu.Lock()
	if s, ok := m.hosts[host]; ok {
		s.failedAt = time.Time{}
		s.lastError = ""
	}
	m.mu.Unlock()
	// stale ControlMaster: 死んだ VM 用に残ってると次の SSH が古い socket 経由で
	// 失敗する。`-O exit` でクリーンに閉じる (なければ no-op)。
	cmd := exec.Command("ssh",
		"-o", "ControlPath="+sshControlPath(host),
		"-O", "exit",
		host,
	)
	_ = cmd.Run()  // 失敗無視 (ControlMaster 居ないと exit 1 だが正常)
}
