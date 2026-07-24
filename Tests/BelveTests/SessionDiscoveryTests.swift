import XCTest
@testable import Belve

final class SessionDiscoveryTests: XCTestCase {
	private let projectA = UUID()

	/// 注入 closure runner。`tmux list-sessions` と各 `tmux list-panes -t <name>` に
	/// canned string を返す。呼ばれたコマンドを記録して parse を検証する。
	private final class FakeRunner {
		/// list-sessions の出力 (nil = tmux 未起動)。
		var sessionsOutput: String?
		/// セッション名 → list-panes 出力。
		var panesOutput: [String: String] = [:]
		private(set) var commands: [String] = []

		func run(_ command: String) -> String? {
			commands.append(command)
			if command.hasPrefix("tmux list-sessions") {
				return sessionsOutput
			}
			if command.hasPrefix("tmux list-panes") {
				// `-t '<name>'` から name を抽出 (single-quote で囲まれている)。
				for (name, output) in panesOutput {
					if command.contains("'\(name)'") { return output }
				}
				return nil
			}
			return nil
		}
	}

	// (a) mixed: 複数セッション出力で agent 検出分だけ返る + prefix フィルタが効く。
	//     bare shell 系 (belve-bbb / belve-ccc) と非 prefix (other/manual) は除外され、
	//     agent (claude/codex) の belve-* だけが .working で返る。
	func testReturnsOnlyAgentSessionsAndFiltersByPrefix() {
		let runner = FakeRunner()
		runner.sessionsOutput = """
		belve-aaa11111
		belve-bbb22222

		other-session
		  belve-ccc33333
		belve-ddd44444
		manual-tmux
		"""
		runner.panesOutput = [
			"belve-aaa11111": "zsh\nclaude",  // agent 検出 → 返る
			"belve-bbb22222": "bash",         // bare shell → 除外
			"belve-ccc33333": "fish",         // bare shell → 除外
			"belve-ddd44444": "codex",        // agent 検出 → 返る
			"other-session": "claude",        // prefix 不一致 → 対象外
			"manual-tmux": "claude",          // prefix 不一致 → 対象外
		]
		let service = SessionDiscoveryService(runCommand: runner.run)
		let discovered = service.discover(projectId: projectA)

		XCTAssertEqual(discovered.map { $0.sessionKey }, ["belve-aaa11111", "belve-ddd44444"])
		XCTAssertTrue(discovered.allSatisfy { $0.coarseStatus == .working })
	}

	// (a') tmux 未起動 (runner nil) / 空出力は空配列。
	func testNilOrEmptyOutputYieldsEmpty() {
		let runner = FakeRunner()
		runner.sessionsOutput = nil
		XCTAssertTrue(SessionDiscoveryService(runCommand: runner.run).discover(projectId: projectA).isEmpty)

		runner.sessionsOutput = "\n  \n"
		XCTAssertTrue(SessionDiscoveryService(runCommand: runner.run).discover(projectId: projectA).isEmpty)
	}

	// (b) agent 検出セッションは .working で返る (claude / codex)。
	func testAgentSessionsAreIncludedAsWorking() {
		let runner = FakeRunner()
		runner.sessionsOutput = "belve-claude\nbelve-codex"
		runner.panesOutput = [
			"belve-claude": "zsh\nclaude",  // いずれかの pane が claude
			"belve-codex": "codex",         // codex
		]
		let service = SessionDiscoveryService(runCommand: runner.run)
		let byKey = Dictionary(uniqueKeysWithValues: service.discover(projectId: projectA).map { ($0.sessionKey, $0.coarseStatus) })

		XCTAssertEqual(byKey["belve-claude"], .working)
		XCTAssertEqual(byKey["belve-codex"], .working)
	}

	// (b') bare shell / node のみのセッションは surface しない (返らない)。
	//      node は汎用ランタイム名なので agentCommands に含めない → 除外。
	func testBareShellAndNodeSessionsAreExcluded() {
		let runner = FakeRunner()
		runner.sessionsOutput = "belve-bash\nbelve-zsh\nbelve-login\nbelve-node"
		runner.panesOutput = [
			"belve-bash": "bash",   // bare shell → 除外
			"belve-zsh": "zsh",     // bare shell → 除外
			"belve-login": "-zsh",  // ログインシェル → 除外
			"belve-node": "node",   // node は agent ではない → 除外
		]
		let service = SessionDiscoveryService(runCommand: runner.run)
		XCTAssertTrue(service.discover(projectId: projectA).isEmpty)
	}

	// (c) mergeDiscovered は未知の SessionKey を discovered として挿入する。
	func testMergeInsertsNewDiscoveredSessions() {
		let store = AgentSessionStore()
		store.mergeDiscovered([
			(sessionKey: "belve-x", coarseStatus: .working),
			(sessionKey: "belve-y", coarseStatus: .idle),
		], projectId: projectA)

		let x = store.session(for: "belve-x")
		let y = store.session(for: "belve-y")
		XCTAssertEqual(x?.origin, .discovered)
		XCTAssertEqual(x?.state.status, .working)
		XCTAssertEqual(x?.projectId, projectA)
		XCTAssertEqual(y?.origin, .discovered)
		XCTAssertEqual(y?.state.status, .idle)
		XCTAssertEqual(store.sessions(forProject: projectA).count, 2)
	}

	// (d) mergeDiscovered は .launched セッションの state を上書きしない (OSC が権威)。
	func testMergeDoesNotOverwriteLaunchedSession() {
		let store = AgentSessionStore()
		// OSC 経路で .launched セッションを blocked にしておく。
		store.updateState(sessionKey: "belve-osc", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-osc", projectId: projectA, hookStatus: "waiting", message: "need input")
		XCTAssertEqual(store.session(for: "belve-osc")?.state.status, .blocked)
		XCTAssertEqual(store.session(for: "belve-osc")?.origin, .launched)

		// discovery が同じ SessionKey を working として報告しても上書きしない。
		store.mergeDiscovered([(sessionKey: "belve-osc", coarseStatus: .working)], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-osc")?.state.status, .blocked)
		XCTAssertEqual(store.session(for: "belve-osc")?.origin, .launched)
	}

	// (d') 既存 .discovered は粗い status を更新する (discovery が所有し続ける)。
	func testMergeUpdatesExistingDiscoveredStatus() {
		let store = AgentSessionStore()
		store.mergeDiscovered([(sessionKey: "belve-d", coarseStatus: .idle)], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-d")?.state.status, .idle)

		store.mergeDiscovered([(sessionKey: "belve-d", coarseStatus: .working)], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-d")?.state.status, .working)
		XCTAssertEqual(store.session(for: "belve-d")?.origin, .discovered)
	}

	// (e) 後続 discover() で消えた discovered セッションは .sessionEnd に落ちる。
	func testMergeMarksAbsentDiscoveredAsSessionEnd() {
		let store = AgentSessionStore()
		store.mergeDiscovered([
			(sessionKey: "belve-gone", coarseStatus: .working),
			(sessionKey: "belve-stay", coarseStatus: .working),
		], projectId: projectA)

		// 次の poll で belve-gone が消える。
		store.mergeDiscovered([(sessionKey: "belve-stay", coarseStatus: .working)], projectId: projectA)

		XCTAssertEqual(store.session(for: "belve-gone")?.state.status, .sessionEnd)
		XCTAssertEqual(store.session(for: "belve-stay")?.state.status, .working)
	}

	// (e') 消えた .launched セッションは absence では touch されない (OSC/edge が所有)。
	func testMergeDoesNotEndAbsentLaunchedSession() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-launched", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-launched", projectId: projectA, hookStatus: "running", message: "go")
		XCTAssertEqual(store.session(for: "belve-launched")?.state.status, .working)

		// discovery が別セッションだけ報告 (launched は list に居ない) → launched は working のまま。
		store.mergeDiscovered([(sessionKey: "belve-other", coarseStatus: .idle)], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-launched")?.state.status, .working)
		XCTAssertEqual(store.session(for: "belve-launched")?.origin, .launched)
	}
}
