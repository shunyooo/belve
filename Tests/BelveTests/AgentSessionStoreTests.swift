import XCTest
@testable import Belve

final class AgentSessionStoreTests: XCTestCase {
	private let projectA = UUID()

	// (a) sessionStart creates a session keyed by SessionKey.
	func testSessionStartCreatesSessionKeyedBySessionKey() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "session_start", message: "start")

		let session = store.session(for: "belve-A")
		XCTAssertNotNil(session)
		XCTAssertEqual(session?.id, "belve-A")
		XCTAssertEqual(session?.projectId, projectA)
		XCTAssertEqual(session?.state.status, .sessionStart)
	}

	// (b) working / blocked / done transitions map from hook strings.
	func testHookStatusTransitions() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "session_start", message: "start")

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "go")
		XCTAssertEqual(store.session(for: "belve-A")?.state.status, .working)

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "waiting", message: "need input")
		XCTAssertEqual(store.session(for: "belve-A")?.state.status, .blocked)

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "completed", message: "Done")
		XCTAssertEqual(store.session(for: "belve-A")?.state.status, .done)
	}

	// (c) tool: / result: / subagent: / subagent-done: parsing.
	func testStructuredMessageParsing() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "session_start", message: "start")

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "tool:Bash:ls -la")
		XCTAssertEqual(store.session(for: "belve-A")?.state.currentTool, "Bash")
		XCTAssertEqual(store.session(for: "belve-A")?.state.lastActivity, "ls -la")

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "result:Bash:done listing")
		XCTAssertEqual(store.session(for: "belve-A")?.state.lastActivity, "done listing")

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "subagent:search the repo")
		XCTAssertEqual(store.session(for: "belve-A")?.state.currentTool, "Agent")
		XCTAssertEqual(store.session(for: "belve-A")?.state.lastActivity, "search the repo")
		XCTAssertEqual(store.session(for: "belve-A")?.state.subagentCount, 1)

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "subagent-done:")
		XCTAssertEqual(store.session(for: "belve-A")?.state.subagentCount, 0)
	}

	// (d) first non-structured prompt becomes `name`.
	func testFirstPromptBecomesName() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "session_start", message: "start")

		// structured events must NOT set the name
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "tool:Bash:ls")
		XCTAssertEqual(store.session(for: "belve-A")?.name, "")

		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "Fix the login bug")
		XCTAssertEqual(store.session(for: "belve-A")?.name, "Fix the login bug")

		// once set, name is sticky
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "Another prompt")
		XCTAssertEqual(store.session(for: "belve-A")?.name, "Fix the login bug")
	}

	// (e) triageOrdered ordering blocked -> working -> done -> idle.
	func testTriageOrdering() {
		let store = AgentSessionStore()
		// create four sessions with distinct terminal states
		store.updateState(sessionKey: "belve-done", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-done", projectId: projectA, hookStatus: "completed", message: "finished")

		store.updateState(sessionKey: "belve-idle", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-idle", projectId: projectA, hookStatus: "idle", message: "")

		store.updateState(sessionKey: "belve-working", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-working", projectId: projectA, hookStatus: "running", message: "go")

		store.updateState(sessionKey: "belve-blocked", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-blocked", projectId: projectA, hookStatus: "waiting", message: "need input")

		let ordered = store.triageOrdered(forProject: projectA).map { $0.id }
		XCTAssertEqual(ordered, ["belve-blocked", "belve-working", "belve-done", "belve-idle"])
	}

	// (f) attentionCount counts blocked.
	func testAttentionAndWorkingCounts() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-1", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-1", projectId: projectA, hookStatus: "waiting", message: "need input")
		store.updateState(sessionKey: "belve-2", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-2", projectId: projectA, hookStatus: "waiting", message: "need input")
		store.updateState(sessionKey: "belve-3", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-3", projectId: projectA, hookStatus: "running", message: "go")

		XCTAssertEqual(store.attentionCount(forProject: projectA), 2)
		XCTAssertEqual(store.workingCount(forProject: projectA), 1)
	}

	// (g) pane binding: bind / lookup / reverse lookup / unbind. Keys lowercased.
	func testPaneBinding() {
		let store = AgentSessionStore()
		store.bind(paneId: "PANE-ONE", sessionKey: "belve-A")
		store.bind(paneId: "pane-two", sessionKey: "belve-A")
		store.bind(paneId: "PANE-THREE", sessionKey: "belve-B")

		// lookup is case-insensitive (keys stored lowercased)
		XCTAssertEqual(store.sessionKey(forPane: "pane-one"), "belve-A")
		XCTAssertEqual(store.sessionKey(forPane: "PANE-ONE"), "belve-A")
		XCTAssertEqual(store.sessionKey(forPane: "pane-three"), "belve-B")
		XCTAssertNil(store.sessionKey(forPane: "missing"))

		// reverse lookup returns lowercased paneIds bound to a SessionKey
		XCTAssertEqual(Set(store.panes(forSession: "belve-A")), ["pane-one", "pane-two"])
		XCTAssertEqual(store.panes(forSession: "belve-B"), ["pane-three"])

		store.unbind(paneId: "pane-one")
		XCTAssertNil(store.sessionKey(forPane: "PANE-ONE"))
		XCTAssertEqual(store.panes(forSession: "belve-A"), ["pane-two"])
	}

	// (h) archive(sessionKey:) hides the session from sessions(forProject:).
	func testArchiveBySessionKey() {
		let store = AgentSessionStore()
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "session_start", message: "s")
		XCTAssertEqual(store.sessions(forProject: projectA).count, 1)

		store.archive(sessionKey: "belve-A")
		XCTAssertTrue(store.sessions(forProject: projectA).isEmpty)
		// record itself is durable (still resolvable by key)
		XCTAssertEqual(store.session(for: "belve-A")?.isArchived, true)
	}

	// (i) rollupStatus returns the most-severe status, nil when none.
	func testRollupStatus() {
		let store = AgentSessionStore()
		XCTAssertNil(store.rollupStatus(forProject: projectA))

		store.updateState(sessionKey: "belve-done", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-done", projectId: projectA, hookStatus: "completed", message: "finished")
		XCTAssertEqual(store.rollupStatus(forProject: projectA), .done)

		store.updateState(sessionKey: "belve-working", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-working", projectId: projectA, hookStatus: "running", message: "go")
		XCTAssertEqual(store.rollupStatus(forProject: projectA), .working)

		store.updateState(sessionKey: "belve-blocked", projectId: projectA, hookStatus: "session_start", message: "s")
		store.updateState(sessionKey: "belve-blocked", projectId: projectA, hookStatus: "waiting", message: "need input")
		XCTAssertEqual(store.rollupStatus(forProject: projectA), .blocked)
	}

	// (j) A .discovered session that receives ANY OSC updateState (here the transport's
	// warm-up flush delivering only a trailing .working, never a session_start) is
	// promoted to origin == .launched, and is therefore NOT ended by a later
	// mergeDiscovered sweep that transiently omits it.
	func testOSCUpdatePromotesDiscoveredOriginToLaunched() {
		let store = AgentSessionStore()

		// discovery first surfaces the raw tmux session (origin == .discovered).
		store.mergeDiscovered([(sessionKey: "belve-A", coarseStatus: .idle)], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-A")?.origin, .discovered)

		// OSC's first observed event is a .working (no session_start) — goes through mutate.
		store.updateState(sessionKey: "belve-A", projectId: projectA, hookStatus: "running", message: "go")
		XCTAssertEqual(store.session(for: "belve-A")?.state.status, .working)
		XCTAssertEqual(store.session(for: "belve-A")?.origin, .launched)

		// A subsequent discovery poll that transiently misses belve-A must NOT end it,
		// because it is now OSC-authoritative (.launched), not .discovered.
		store.mergeDiscovered([], projectId: projectA)
		XCTAssertEqual(store.session(for: "belve-A")?.state.status, .working)
		XCTAssertNotEqual(store.session(for: "belve-A")?.state.status, .sessionEnd)
	}
}
