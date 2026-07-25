import XCTest
@testable import Belve

final class PaneCreationTests: XCTestCase {

	// addPane(sessionName:) は新 pane を active にし、その leaf に
	// sessionNameOverride を焼き込む (overrideSocket は nil のまま)。
	func testAddPaneWithSessionNameSetsOverrideOnNewLeaf() {
		let state = CommandAreaState()
		let before = state.orderedPaneIds().count

		let newId = state.addPane(direction: .vertical, sessionName: "backend")
		XCTAssertNotNil(newId)
		XCTAssertEqual(state.activePaneId, newId)
		XCTAssertEqual(state.orderedPaneIds().count, before + 1)

		let leaf = state.findLeafByPaneId(newId!, in: state.root)
		XCTAssertEqual(leaf?.sessionNameOverride, "backend")
		XCTAssertNil(leaf?.overrideSocket)
	}

	// addPane(overrideSocket:) は attach 用に socket を焼き込む
	// (sessionNameOverride は nil)。
	func testAddPaneWithOverrideSocketSetsSocketOnNewLeaf() {
		let state = CommandAreaState()
		let sock = "/tmp/belve-shell/sessions/belve-abc-foo.sock"

		let newId = state.addPane(direction: .horizontal, overrideSocket: sock)
		XCTAssertNotNil(newId)

		let leaf = state.findLeafByPaneId(newId!, in: state.root)
		XCTAssertEqual(leaf?.overrideSocket, sock)
		XCTAssertNil(leaf?.sessionNameOverride)
	}

	// 紐付け済み pane の隣に split しても、その pane の override は保持される
	// (spawnNode が残す側へ引き継ぐ)。回帰防止。
	func testSplitPreservesExistingPaneOverride() {
		let state = CommandAreaState()
		guard let first = state.root.paneId else { return XCTFail("no first pane") }
		state.findLeafByPaneId(first, in: state.root)?.tmuxSessionOverride = "clay-seto"
		state.findLeafByPaneId(first, in: state.root)?.overrideSocket = "/tmp/x.sock"
		state.activePaneId = first
		state.addPane(direction: .vertical)
		let leaf = state.findLeafByPaneId(first, in: state.root)
		XCTAssertEqual(leaf?.tmuxSessionOverride, "clay-seto")
		XCTAssertEqual(leaf?.overrideSocket, "/tmp/x.sock")
	}

	// allLeaves は現在レイアウトの全 leaf pane を返す (使用中セッション集計の土台)。
	func testAllLeavesCountsPanes() {
		let state = CommandAreaState()
		XCTAssertEqual(state.allLeaves().count, 1)
		state.addPane()
		state.addPane()
		XCTAssertEqual(state.allLeaves().count, 3)
	}

	// addPane(tmuxSessionName:) は新 leaf に tmuxSessionOverride を焼き込む
	// (remote 既存 tmux セッションへの attach 用)。他 override は nil。
	func testAddPaneWithTmuxSessionSetsOverrideOnNewLeaf() {
		let state = CommandAreaState()
		let newId = state.addPane(direction: .vertical, tmuxSessionName: "clay-seto")
		XCTAssertNotNil(newId)
		let leaf = state.findLeafByPaneId(newId!, in: state.root)
		XCTAssertEqual(leaf?.tmuxSessionOverride, "clay-seto")
		XCTAssertNil(leaf?.sessionNameOverride)
		XCTAssertNil(leaf?.overrideSocket)
	}

	// PaneNode の tmuxSessionOverride は Codable round-trip で保持される。
	func testPaneNodeTmuxSessionOverrideCodableRoundTrip() throws {
		let node = PaneNode(paneId: UUID(), paneIndex: 0)
		node.tmuxSessionOverride = "peakrail"
		let data = try JSONEncoder().encode(node)
		let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
		XCTAssertEqual(decoded.tmuxSessionOverride, "peakrail")
	}

	// 引数なしの addPane は従来どおり自動命名 (両 override とも nil)。
	func testAddPaneWithoutArgsLeavesOverridesNil() {
		let state = CommandAreaState()
		let newId = state.addPane()
		let leaf = state.findLeafByPaneId(newId!, in: state.root)
		XCTAssertNil(leaf?.sessionNameOverride)
		XCTAssertNil(leaf?.overrideSocket)
	}

	// PaneNode の sessionNameOverride は Codable round-trip で保持される。
	func testPaneNodeSessionNameOverrideCodableRoundTrip() throws {
		let node = PaneNode(paneId: UUID(), paneIndex: 0)
		node.sessionNameOverride = "logs"
		node.overrideSocket = "/tmp/x.sock"
		let data = try JSONEncoder().encode(node)
		let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
		XCTAssertEqual(decoded.sessionNameOverride, "logs")
		XCTAssertEqual(decoded.overrideSocket, "/tmp/x.sock")
	}

	// セッション名トークンの正規化: 不正文字→'-'、前後の '-' 除去、空→nil。
	func testSanitizedSessionToken() {
		XCTAssertNil(PaneSessionNaming.sanitizedToken(nil))
		XCTAssertNil(PaneSessionNaming.sanitizedToken(""))
		XCTAssertNil(PaneSessionNaming.sanitizedToken("   "))
		XCTAssertNil(PaneSessionNaming.sanitizedToken("!!!"))
		XCTAssertEqual(PaneSessionNaming.sanitizedToken("backend"), "backend")
		XCTAssertEqual(PaneSessionNaming.sanitizedToken("my session!"), "my-session")
		XCTAssertEqual(PaneSessionNaming.sanitizedToken("--api--"), "api")
		XCTAssertEqual(PaneSessionNaming.sanitizedToken("a_b-c1"), "a_b-c1")
	}

	// セッション名の確定規則: overrideSocket → 命名 → paneId 自動、の優先順位。
	func testSessionNameResolution() {
		// overrideSocket 優先 (basename から .sock を除去)
		XCTAssertEqual(
			PaneSessionNaming.sessionName(projShort: "abc12345", paneIdString: "PANEIDXX-....", sessionNameOverride: "ignored", overrideSocket: "/tmp/belve-shell/sessions/belve-xyz-logs.sock"),
			"belve-xyz-logs"
		)
		// ユーザー命名
		XCTAssertEqual(
			PaneSessionNaming.sessionName(projShort: "abc12345", paneIdString: "PANEIDXX-....", sessionNameOverride: "back end", overrideSocket: nil),
			"belve-abc12345-back-end"
		)
		// 自動 (paneId 先頭8桁)
		XCTAssertEqual(
			PaneSessionNaming.sessionName(projShort: "abc12345", paneIdString: "0123456789ABCDEF", sessionNameOverride: nil, overrideSocket: nil),
			"belve-abc12345-01234567"
		)
	}
}
