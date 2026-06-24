package main

// Mac mac-master 側の SSH channel 多重化 (Phase 6)。
// docs/notes/2026-06-24-yamux-multiplex.md 参照。
//
// 役割:
//   - host ごとに 1 個の yamux client session を維持
//   - Per-host Unix socket /tmp/belve-mux-listener-<slug>.sock を listen
//   - Unix socket に来た接続 1 個 = yamux stream 1 個に bridge
//   - SSH forward (19201) は tunnelManager に張ってもらう
//
// 旧 path (per-pane TCP 直接 dial) と完全分離して実装。pane client が
// `-mux-via PATH` で接続しに来ない限り、ここのコードは一切動かない。

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/libp2p/go-yamux/v5"
)

// muxRouterRemotePort: VM 側 router が yamux 用に listen してる port。
// belve-setup の `-mux-router 127.0.0.1:19201` と整合させる。
const muxRouterRemotePort = 19201

// muxListenerPath: host ごとの Unix socket 経路。
// host 名そのまま使うと path が長くなるので sha1 prefix で短縮 (= path 長制限回避)。
func muxListenerPath(host string) string {
	h := sha1.Sum([]byte(host))
	return fmt.Sprintf("/tmp/belve-mux-listener-%s.sock", hex.EncodeToString(h[:6]))
}

type muxManager struct {
	tunnel *tunnelManager

	mu               sync.Mutex
	sessions         map[string]*yamux.Session // host → session
	sessionsSpawning map[string]chan struct{}  // host → "spawn in progress" lock
	listeners        map[string]net.Listener   // host → listener (lifecycle 管理用)
}

func newMuxManager(tunnel *tunnelManager) *muxManager {
	return &muxManager{
		tunnel:           tunnel,
		sessions:         make(map[string]*yamux.Session),
		sessionsSpawning: make(map[string]chan struct{}),
		listeners:        make(map[string]net.Listener),
	}
}

// ensureListener: host ごとに per-host Unix socket listener を起動する。冪等。
// `tunnelManager.ensureRouterForward(host, 19200)` と並列で呼ばれて構わない
// (= mux session 確立は lazy、初回 client 接続まで遅延)。
func (mm *muxManager) ensureListener(host string) error {
	mm.mu.Lock()
	if _, ok := mm.listeners[host]; ok {
		mm.mu.Unlock()
		return nil
	}
	mm.mu.Unlock()

	sockPath := muxListenerPath(host)
	_ = os.Remove(sockPath)
	if err := os.MkdirAll(filepath.Dir(sockPath), 0o755); err != nil {
		return fmt.Errorf("mkdir for mux listener: %w", err)
	}
	listener, err := net.Listen("unix", sockPath)
	if err != nil {
		return fmt.Errorf("listen unix %s: %w", sockPath, err)
	}

	mm.mu.Lock()
	mm.listeners[host] = listener
	mm.mu.Unlock()

	fmt.Fprintf(os.Stderr, "[belve-master] mux listener up for %s at %s\n", host, sockPath)
	go mm.acceptLoop(host, listener)
	return nil
}

func (mm *muxManager) acceptLoop(host string, listener net.Listener) {
	for {
		client, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-master] mux listener accept (%s): %v\n", host, err)
			return
		}
		go mm.handleClient(host, client)
	}
}

func (mm *muxManager) handleClient(host string, client net.Conn) {
	defer client.Close()
	muxTraceMac("client-accept host=%s", host)

	sess, err := mm.ensureSession(host)
	if err != nil {
		// 明示的エラー: silent fallback はしない。pane client が EOF を受けて
		// reconnect ループに入る。問題の存在をユーザーに見える形で残す。
		fmt.Fprintf(os.Stderr, "[belve-master] mux ensureSession (%s): %v\n", host, err)
		// 注意: 標準エラーで /dev/null へ捨てられる構成なので、Mac master の
		// stderr が見えないと診断しづらい。Belve.app の Log Stream で拾える前提。
		return
	}

	stream, err := sess.OpenStream(context.Background())
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-master] mux OpenStream (%s): %v\n", host, err)
		return
	}
	defer stream.Close()
	muxTraceMac("stream-open host=%s id=%d", host, stream.StreamID())

	// 双方向 piping。client (= pane の belve-persist) ↔ stream (= yamux)。
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(stream, client)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(client, stream)
		done <- struct{}{}
	}()
	<-done
	muxTraceMac("stream-close host=%s id=%d", host, stream.StreamID())
}

// ensureSession: host 用 yamux client session を取得 (or 新規作成)。
// session が死んだら CloseChan 経由で lazy に cleanup。次回呼び出しで再生成。
// 並列呼び出しは sessionsSpawning chan で one-shot serialize する。
func (mm *muxManager) ensureSession(host string) (*yamux.Session, error) {
	mm.mu.Lock()
	if sess, ok := mm.sessions[host]; ok && !sess.IsClosed() {
		mm.mu.Unlock()
		return sess, nil
	}
	// もし spawning 中なら待つ。
	if waitCh, ok := mm.sessionsSpawning[host]; ok {
		mm.mu.Unlock()
		<-waitCh
		mm.mu.Lock()
		defer mm.mu.Unlock()
		if sess, ok := mm.sessions[host]; ok && !sess.IsClosed() {
			return sess, nil
		}
		return nil, fmt.Errorf("mux session spawn failed for %s", host)
	}
	// この goroutine が spawn を担当する。
	waitCh := make(chan struct{})
	mm.sessionsSpawning[host] = waitCh
	mm.mu.Unlock()

	sess, err := mm.spawnSession(host)

	mm.mu.Lock()
	delete(mm.sessionsSpawning, host)
	if err == nil {
		mm.sessions[host] = sess
		go mm.watchSession(host, sess)
	}
	mm.mu.Unlock()
	close(waitCh)
	return sess, err
}

func (mm *muxManager) spawnSession(host string) (*yamux.Session, error) {
	port, err := mm.tunnel.ensureRouterForward(host, muxRouterRemotePort)
	if err != nil {
		return nil, fmt.Errorf("ensureRouterForward(mux): %w", err)
	}
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("dial mux router %s: %w", addr, err)
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
	}
	sess, err := yamux.Client(conn, muxYamuxConfig(), nil)
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("yamux.Client: %w", err)
	}
	fmt.Fprintf(os.Stderr, "[belve-master] mux session up host=%s addr=%s\n", host, addr)
	muxTraceMac("session-open host=%s addr=%s", host, addr)
	return sess, nil
}

// watchSession: session の死亡を待って sessions[host] を clear。次回 ensureSession
// で lazy に再構築される (= thundering herd 回避、必要な時だけ復活)。
func (mm *muxManager) watchSession(host string, sess *yamux.Session) {
	<-sess.CloseChan()
	mm.mu.Lock()
	if mm.sessions[host] == sess {
		delete(mm.sessions, host)
	}
	mm.mu.Unlock()
	fmt.Fprintf(os.Stderr, "[belve-master] mux session closed host=%s\n", host)
	muxTraceMac("session-close host=%s", host)
}

// status: 現在の session/stream 数を返す。SettingsView の Mux status 表示用 (Phase 5)。
func (mm *muxManager) status() []muxSessionStatus {
	mm.mu.Lock()
	defer mm.mu.Unlock()
	out := make([]muxSessionStatus, 0, len(mm.sessions))
	for host, sess := range mm.sessions {
		out = append(out, muxSessionStatus{
			Host:       host,
			NumStreams: sess.NumStreams(),
			IsClosed:   sess.IsClosed(),
		})
	}
	return out
}

type muxSessionStatus struct {
	Host       string `json:"host"`
	NumStreams int    `json:"numStreams"`
	IsClosed   bool   `json:"isClosed"`
}

// muxTraceMac: BELVE_MUX_TRACE=1 の時だけ /tmp/belve-mux-mac.log に append。
// VM 側と同じ思想で binary payload は記録しない。
var (
	muxTraceMacMu   sync.Mutex
	muxTraceMacFile *os.File
	muxTraceMacInit sync.Once
)

func muxTraceMac(format string, args ...interface{}) {
	if os.Getenv("BELVE_MUX_TRACE") != "1" {
		return
	}
	muxTraceMacInit.Do(func() {
		f, err := os.OpenFile("/tmp/belve-mux-mac.log",
			os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err == nil {
			muxTraceMacFile = f
		}
	})
	muxTraceMacMu.Lock()
	defer muxTraceMacMu.Unlock()
	if muxTraceMacFile == nil {
		return
	}
	fmt.Fprintf(muxTraceMacFile, "%s "+format+"\n",
		append([]interface{}{time.Now().Format(time.RFC3339Nano)}, args...)...)
}

// globalMuxManager: mac-master 起動時にセット。0 値 (nil) の状態でも他 mode に
// 影響しない。
var globalMuxManager *muxManager
