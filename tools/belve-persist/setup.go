package main

// Mac master daemon の setup orchestration。
//
// 元々は bash launcher が `scp tar` + `ssh host belve-setup` を pane ごとに
// 実行してて、N pane 並列で MaxSessions 枯渇 / FD leak / lock stale 等の
// バグを量産してた。これを Go の master が project ごとに 1 回だけ実行する
// 形に集約する。
//
// 設計:
//   - per-host で sync.Mutex 直列化 (= 同時 SSH session 数 = 1)
//   - per-project で SetupState を持ち、idempotent に応答
//     (= 既に done なら即返却、in-progress なら待つ、failed なら error 返す)
//   - 結果を Belve.app に返した後、broker が落ちて再 setup が必要になった時は
//     `invalidateSetup` op で state をリセットさせる (Phase 4 で実装予定)。

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
)

type setupState int

const (
	setupIdle    setupState = iota
	setupRunning            // 進行中。他の caller は wait
	setupReady              // 完了。即返却
	setupFailed             // 失敗。error 込みで返す
)

func (s setupState) String() string {
	switch s {
	case setupIdle:
		return "idle"
	case setupRunning:
		return "running"
	case setupReady:
		return "ready"
	case setupFailed:
		return "failed"
	default:
		return "unknown"
	}
}

type projectSetup struct {
	state setupState
	err   string
	done  chan struct{} // running の間 close 待ち
}

type setupManager struct {
	mu        sync.Mutex
	projects  map[string]*projectSetup // keyed by projectId
	hostLocks map[string]*sync.Mutex   // per-host SSH session 直列化
}

var globalSetupManager = &setupManager{
	projects:  map[string]*projectSetup{},
	hostLocks: map[string]*sync.Mutex{},
}

// invalidate: 指定 project の状態をリセット (= 次回 ensureSetup で再実行)。
// container rebuild / broker 死亡など、再 setup が必要な事象を Belve.app が
// 検知した時に呼ぶ。
func (sm *setupManager) invalidate(projectID string) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	delete(sm.projects, projectID)
}

func (sm *setupManager) hostLock(host string) *sync.Mutex {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	if l, ok := sm.hostLocks[host]; ok {
		return l
	}
	l := &sync.Mutex{}
	sm.hostLocks[host] = l
	return l
}

// ensureSetup: project の setup が完了している事を保証する。
// 既に done なら即返却。進行中なら待つ。idle/failed なら走らせる。
//
// 戻り値の state は最終状態 (ready or failed)。
func (sm *setupManager) ensureSetup(req setupReq) (setupState, string) {
	sm.mu.Lock()
	ps, exists := sm.projects[req.ProjectID]
	if !exists {
		ps = &projectSetup{state: setupIdle}
		sm.projects[req.ProjectID] = ps
	}
	switch ps.state {
	case setupReady:
		sm.mu.Unlock()
		return setupReady, ""
	case setupRunning:
		ch := ps.done
		sm.mu.Unlock()
		<-ch
		// 完了を通知された。再評価
		sm.mu.Lock()
		st, e := ps.state, ps.err
		sm.mu.Unlock()
		return st, e
	}
	// idle / failed: 走らせる
	ps.state = setupRunning
	ps.err = ""
	ps.done = make(chan struct{})
	sm.mu.Unlock()

	st, errStr := sm.runSetup(req)

	sm.mu.Lock()
	ps.state = st
	ps.err = errStr
	close(ps.done)
	sm.mu.Unlock()
	return st, errStr
}

type setupReq struct {
	ProjectID     string
	Host          string
	IsDevContainer bool
	WorkspacePath string // remote path (= ~/src/foo)
	ProjShort     string // UUID 先頭 8 文字
	BinDir        string // Mac 側 binary 置き場 (Belve.app/Contents/Resources/bin)
}

func (sm *setupManager) runSetup(req setupReq) (setupState, string) {
	if req.Host == "" || req.ProjectID == "" || req.BinDir == "" {
		return setupFailed, "missing required field (host/projectId/binDir)"
	}
	// Per-host 直列化: 同 VM への SCP/SSH を 1 本に絞り MaxSessions 枯渇を防ぐ。
	hl := sm.hostLock(req.Host)
	hl.Lock()
	defer hl.Unlock()

	if err := deployBundle(req.Host, req.BinDir); err != nil {
		return setupFailed, fmt.Sprintf("deploy: %v", err)
	}
	if err := runBelveSetup(req); err != nil {
		return setupFailed, fmt.Sprintf("belve-setup: %v", err)
	}
	return setupReady, ""
}

// SSH ControlMaster の path 命名規則は launcher と互換性がある形にする。
// 既存の SSHTunnelManager.swift / belve-launcher.sh と同じ。
func sshControlPath(host string) string {
	return "/tmp/belve-ssh-ctrl-" + host
}

func sshOpts(host string) []string {
	return []string{
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + sshControlPath(host),
		"-o", "ControlPersist=600",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "ConnectTimeout=10",
	}
}

// deployBundle: Mac 側 binDir の内容を tar で固めて host に SCP し、
// remote 側で md5 比較→不一致なら展開。Phase 0 の bash launcher と同等の挙動。
func deployBundle(host, binDir string) error {
	tmpTar, err := os.CreateTemp("", "belve-deploy-*.tar.gz")
	if err != nil {
		return fmt.Errorf("create tmp tar: %w", err)
	}
	tmpTarPath := tmpTar.Name()
	tmpTar.Close()
	defer os.Remove(tmpTarPath)

	// 中身: bin/{belve, claude, codex, belve-setup, belve-persist-linux-amd64,
	// belve-persist-linux-arm64} + session-bootstrap.sh。
	// remote では ~/.belve/ 配下に展開される。
	staging, err := os.MkdirTemp("", "belve-stage-*")
	if err != nil {
		return fmt.Errorf("mkdtemp staging: %w", err)
	}
	defer os.RemoveAll(staging)

	if err := os.MkdirAll(filepath.Join(staging, "bin"), 0o755); err != nil {
		return fmt.Errorf("mkdir staging/bin: %w", err)
	}

	files := []struct {
		src string
		dst string
	}{
		{filepath.Join(binDir, "belve"), filepath.Join(staging, "bin", "belve")},
		{filepath.Join(binDir, "claude"), filepath.Join(staging, "bin", "claude")},
		{filepath.Join(binDir, "codex"), filepath.Join(staging, "bin", "codex")},
		{filepath.Join(binDir, "belve-setup"), filepath.Join(staging, "bin", "belve-setup")},
		{filepath.Join(binDir, "belve-persist-linux-amd64"), filepath.Join(staging, "bin", "belve-persist-linux-amd64")},
		{filepath.Join(binDir, "belve-persist-linux-arm64"), filepath.Join(staging, "bin", "belve-persist-linux-arm64")},
		{filepath.Join(binDir, "session-bootstrap.sh"), filepath.Join(staging, "session-bootstrap.sh")},
	}
	for _, f := range files {
		if _, err := os.Stat(f.src); err != nil {
			// 一部 (codex 等) は環境によって無いことがある。silent skip。
			continue
		}
		if err := copyFile(f.src, f.dst); err != nil {
			return fmt.Errorf("copy %s: %w", f.src, err)
		}
	}

	// tar czf ...
	tarCmd := exec.Command("tar", "czf", tmpTarPath, "-C", staging, ".")
	if out, err := tarCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("tar: %v: %s", err, out)
	}

	// md5 (Mac の md5 コマンドは GNU と違う出力なので明示的に awk)
	md5sumCmd := exec.Command("md5", "-q", tmpTarPath)
	md5Out, err := md5sumCmd.Output()
	if err != nil {
		return fmt.Errorf("md5: %w", err)
	}
	localMD5 := string(md5Out)
	for len(localMD5) > 0 && (localMD5[len(localMD5)-1] == '\n' || localMD5[len(localMD5)-1] == '\r') {
		localMD5 = localMD5[:len(localMD5)-1]
	}

	// scp
	scpArgs := append([]string{}, sshOpts(host)...)
	scpArgs = append(scpArgs, "-q", tmpTarPath, host+":/tmp/belve-deploy.tar.gz")
	scpCmd := exec.Command("scp", scpArgs...)
	if out, err := scpCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("scp: %v: %s", err, out)
	}

	// remote 展開 (md5 一致なら skip)
	remoteScript := fmt.Sprintf(`
		if [ -f ~/.belve/.deploy-md5 ] && [ "$(cat ~/.belve/.deploy-md5)" = '%s' ]; then
			rm -f /tmp/belve-deploy.tar.gz
			exit 0
		fi
		mkdir -p ~/.belve/bin ~/.belve/sessions ~/.belve/zdotdir ~/.belve/projects
		tar xzf /tmp/belve-deploy.tar.gz -C ~/.belve
		ARCH=$(uname -m)
		if [ "$ARCH" = 'aarch64' ] || [ "$ARCH" = 'arm64' ]; then
			mv -f ~/.belve/bin/belve-persist-linux-arm64 ~/.belve/bin/belve-persist
		else
			mv -f ~/.belve/bin/belve-persist-linux-amd64 ~/.belve/bin/belve-persist
		fi
		rm -f ~/.belve/bin/belve-persist-linux-amd64 ~/.belve/bin/belve-persist-linux-arm64
		chmod +x ~/.belve/bin/* ~/.belve/session-bootstrap.sh 2>/dev/null
		echo '%s' > ~/.belve/.deploy-md5
		rm -f /tmp/belve-deploy.tar.gz
	`, localMD5, localMD5)

	sshArgs := append([]string{}, sshOpts(host)...)
	sshArgs = append(sshArgs, host, remoteScript)
	sshCmd := exec.Command("ssh", sshArgs...)
	if out, err := sshCmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ssh extract: %v: %s", err, out)
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode())
	if err != nil {
		return err
	}
	defer out.Close()
	_, err = io.Copy(out, in)
	return err
}

// runBelveSetup: ssh host で belve-setup を起動。flag は project の種類で分岐。
func runBelveSetup(req setupReq) error {
	cmd := "$HOME/.belve/bin/belve-setup"
	if req.IsDevContainer {
		cmd += fmt.Sprintf(" --devcontainer --workspace %s --project-short %s",
			shellEscape(req.WorkspacePath), shellEscape(req.ProjShort))
	}
	args := append([]string{}, sshOpts(req.Host)...)
	args = append(args, req.Host, cmd)
	c := exec.Command("ssh", args...)
	out, err := c.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, out)
	}
	return nil
}

func shellEscape(s string) string {
	// 簡易 shell escape。spaces / quotes / special chars 含むパスを想定し、
	// シングルクォートで囲んで内部の ' を '\\'' に置換。
	out := []byte("'")
	for _, c := range []byte(s) {
		if c == '\'' {
			out = append(out, []byte("'\\''")...)
		} else {
			out = append(out, c)
		}
	}
	out = append(out, '\'')
	return string(out)
}
