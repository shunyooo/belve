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
		typealias C = XTermTerminalView.Coordinator
		XCTAssertNil(C.sanitizedSessionToken(nil))
		XCTAssertNil(C.sanitizedSessionToken(""))
		XCTAssertNil(C.sanitizedSessionToken("   "))
		XCTAssertNil(C.sanitizedSessionToken("!!!"))
		XCTAssertEqual(C.sanitizedSessionToken("backend"), "backend")
		XCTAssertEqual(C.sanitizedSessionToken("my session!"), "my-session")
		XCTAssertEqual(C.sanitizedSessionToken("--api--"), "api")
		XCTAssertEqual(C.sanitizedSessionToken("a_b-c1"), "a_b-c1")
	}
}
