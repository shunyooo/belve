package main

// VM-side router. Mac から SSH forward 1 本でここに到着する全接続を、
// VM-local broker (loopback) に proxy する。
//
// Wire 仕様: 接続後、最初の 1 行に NDJSON でルーティング情報を送る。
//   {"kind":"pty"}     → 127.0.0.1:19223 (PTY broker) へ
//   {"kind":"control"} → 127.0.0.1:19225 (control RPC) へ
//
// preamble の後ろに本来のプロトコル (PTY なら msgSession、control なら NDJSON
// req) がそのまま続く。router は preamble を消費した後、buffered な残バイトを
// upstream に書き出してから `io.Copy` で双方向 piping する。
//
// preamble は互換性のため `projShort` フィールドも運ぶが (wire format 不変)、
// 現在は使用しない。全接続は VM-local broker に向かう。

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"

	"github.com/libp2p/go-yamux/v5"
)

// VM-local broker が listen してる loopback ポート。
// router 自身は :19222 を取るので、ローカル broker は別ポートで起動する。
const routerLocalBrokerPort = 19223

type routePreamble struct {
	ProjShort string `json:"projShort"` // 互換のため保持。現在は未使用。
	Kind      string `json:"kind"`      // "pty" | "control"
}

// muxYamuxConfig: Belve のユースケース (claude TUI + MCP の重い burst, replay
// buffer 4 MiB) に合わせたチューニング。詳細は
// docs/notes/2026-06-24-yamux-multiplex.md 参照。
//
// KeepAliveInterval / ConnectionWriteTimeout は Mac laptop の sleep 耐性に
// 直結するパラメータ:
//   - KeepAliveInterval: 何もない時 yamux が ping を打つ間隔。これを超える
//     sleep をすると idle pane でも session が死ぬ。
//   - ConnectionWriteTimeout: write が block した時の timeout。sleep 中に
//     VM 側が active pane に何か出力すると Mac TCP recv buffer が満杯 →
//     yamux write が block → この時間で session 死亡。
//
// 初期値 (30s / 10s) は標準的だがノート PC の蓋閉じで簡単に死ぬので、
// 5 min / 30 s に拡張する。trade-off は「本当に死んだ session の検知が
// 最大 5 分遅れる」だが、1 VM / 1 user 規模では資源リーク無視できる。
func muxYamuxConfig() *yamux.Config {
	cfg := yamux.DefaultConfig()
	cfg.MaxStreamWindowSize = 16 << 20 // 16 MiB
	cfg.KeepAliveInterval = 5 * time.Minute
	cfg.ConnectionWriteTimeout = 30 * time.Second
	cfg.AcceptBacklog = 256
	return cfg
}

// runMuxRouter: Mac mac-master からの yamux session を accept する。1 TCP =
// 1 yamux session = N streams で、各 stream が 1 pane / 1 control RPC に対応する。
// Stream は既存 router の preamble protocol をそのまま流す (= dispatchRouterStream 流用)。
func runMuxRouter(listenAddr string) {
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] mux-router listen %s: %v\n", listenAddr, err)
		return
	}
	fmt.Fprintf(os.Stderr, "[belve-persist] mux-router listening on %s\n", listenAddr)
	for {
		client, err := listener.Accept()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router accept: %v\n", err)
			continue
		}
		go handleMuxSession(client)
	}
}

func handleMuxSession(conn net.Conn) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router session panic: %v\n", r)
		}
	}()
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
	}
	sess, err := yamux.Server(conn, muxYamuxConfig(), nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] yamux.Server: %v\n", err)
		conn.Close()
		return
	}
	defer sess.Close()
	for {
		stream, err := sess.AcceptStream()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[belve-persist] mux-router AcceptStream: %v\n", err)
			return
		}
		go handleMuxStream(stream)
	}
}

func handleMuxStream(stream *yamux.Stream) {
	defer stream.Close()
	muxTraceVM("stream-open id=%d", stream.StreamID())
	_ = stream.SetReadDeadline(time.Now().Add(5 * time.Second))
	reader := bufio.NewReader(stream)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] mux-router preamble read: %v\n", err)
		return
	}
	_ = stream.SetReadDeadline(time.Time{})

	pre, ok := parseAndValidatePreamble(line)
	if !ok {
		return
	}
	muxTraceVM("stream-route id=%d projShort=%q kind=%q", stream.StreamID(), pre.ProjShort, pre.Kind)
	dispatchRouterStream(stream, reader, pre)
	muxTraceVM("stream-close id=%d", stream.StreamID())
}

// muxTraceVM: BELVE_MUX_TRACE=1 の時だけ /tmp/belve-mux-vm.log に append。
// binary payload は記録しない (= 30 GB log 事故防止)。preamble / lifecycle のみ。
var (
	muxTraceMu   sync.Mutex
	muxTraceFile *os.File
	muxTraceInit sync.Once
)

func muxTraceVM(format string, args ...interface{}) {
	if os.Getenv("BELVE_MUX_TRACE") != "1" {
		return
	}
	muxTraceInit.Do(func() {
		f, err := os.OpenFile("/tmp/belve-mux-vm.log",
			os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err == nil {
			muxTraceFile = f
		}
	})
	muxTraceMu.Lock()
	defer muxTraceMu.Unlock()
	if muxTraceFile == nil {
		return
	}
	fmt.Fprintf(muxTraceFile, "%s "+format+"\n",
		append([]interface{}{time.Now().Format(time.RFC3339Nano)}, args...)...)
}

// parseAndValidatePreamble: NDJSON preamble 1 行を読んで validate する。
// `handleMuxStream` から呼ばれる。
func parseAndValidatePreamble(line []byte) (routePreamble, bool) {
	var pre routePreamble
	if err := json.Unmarshal(line, &pre); err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router preamble parse err: %v line=%q\n", err, line)
		return pre, false
	}
	if pre.Kind != "pty" && pre.Kind != "control" {
		fmt.Fprintf(os.Stderr, "[belve-persist] router unknown kind: %q\n", pre.Kind)
		return pre, false
	}
	return pre, true
}

// dispatchRouterStream: preamble 解析済みの client (= raw TCP or yamux.Stream)
// を upstream broker に proxy する。preamble 後の buffered byte は upstream へ
// flush。bidir copy。
//
// `client` の SetNoDelay は TCPConn の時だけ有効。yamux.Stream は internal flow
// control を持つので NoDelay 操作不要。
func dispatchRouterStream(client net.Conn, reader *bufio.Reader, pre routePreamble) {
	target, err := resolveTarget(pre)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router resolve err: %v projShort=%q kind=%q\n", err, pre.ProjShort, pre.Kind)
		return
	}

	upstream, err := dialWithHealing(target)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[belve-persist] router dial %s: %v\n", target, err)
		return
	}
	defer upstream.Close()

	// PTY は 1 byte ずつ流れる事が多い (キーストローク)。Nagle が効くと
	// パケット集約で ~40-200ms の遅延が乗るので両方向で TCP_NODELAY を有効化。
	// yamux.Stream は対象外 (= 内部で flow control 済み)。
	if tc, ok := client.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	if tc, ok := upstream.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}

	// 双方向 piping。bufio に残ってる byte を先に upstream へ流す。
	go func() {
		// upstream → client
		_, _ = io.Copy(client, upstream)
		_ = client.SetReadDeadline(time.Now()) // pump 1 を解除 (TCPConn のみ効く)
	}()
	if buffered := reader.Buffered(); buffered > 0 {
		head := make([]byte, buffered)
		_, _ = io.ReadFull(reader, head)
		if _, err := upstream.Write(head); err != nil {
			return
		}
	}
	// client → upstream
	_, _ = io.Copy(upstream, client)
}

// dialWithHealing: VM-local broker (loopback) に dial する。broker が accept
// loop 詰まり / GC pause 等で瞬間的に応答しない偽陽性を吸収するため 5 秒 × 3
// 試行で粘る。3 回連続失敗 = broker が本当に死んでいるので諦める
// (優しい fallback は入れない — ensure_vm_broker が別経路で broker を保つ)。
func dialWithHealing(target string) (net.Conn, error) {
	var lastErr error
	for i := 0; i < 3; i++ {
		conn, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err == nil {
			return conn, nil
		}
		lastErr = err
		// ECONNREFUSED は broker process そのものが居ない時に瞬時に返る。
		// 一旦間を置く必要はあるが、長く待っても無駄なので 200ms だけ。
		time.Sleep(200 * time.Millisecond)
	}
	fmt.Fprintf(os.Stderr, "[belve-persist] router dial %s failed 3x (last=%v)\n", target, lastErr)
	return nil, fmt.Errorf("dial %s failed: %w", target, lastErr)
}

// resolveTarget: 全接続を VM-local broker (loopback) に向ける。
func resolveTarget(pre routePreamble) (string, error) {
	return fmt.Sprintf("127.0.0.1:%d", localPortFor(pre.Kind)), nil
}

// VM-local broker は 19222 (router) と被らないよう別ポート。
// PTY = 19223、control = 19225。
func localPortFor(kind string) int {
	if kind == "control" {
		return 19225
	}
	return routerLocalBrokerPort
}
