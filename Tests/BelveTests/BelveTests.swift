import XCTest
@testable import Belve

final class BelveTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }

	func testMovePaneInsertsToLeftOfTarget() {
		let state = CommandAreaState()
		guard let firstId = state.root.paneId else {
			return XCTFail("Expected first pane")
		}
		state.activePaneId = firstId
		state.splitActive(.horizontal)

		guard let secondId = leafIds(in: state.root).first(where: { $0 != firstId }) else {
			return XCTFail("Expected second pane")
		}

		state.movePane(secondId, relativeTo: firstId, position: .left)

		XCTAssertEqual(leafIds(in: state.root), [secondId, firstId])
		XCTAssertEqual(state.root.splitDirection, .horizontal)
	}

	func testMovePaneInsertsBelowTarget() {
		let state = CommandAreaState()
		guard let firstId = state.root.paneId else {
			return XCTFail("Expected first pane")
		}
		state.activePaneId = firstId
		state.splitActive(.horizontal)

		guard let secondId = leafIds(in: state.root).first(where: { $0 != firstId }) else {
			return XCTFail("Expected second pane")
		}

		state.movePane(secondId, relativeTo: firstId, position: .bottom)

		XCTAssertEqual(leafIds(in: state.root), [firstId, secondId])
		XCTAssertEqual(state.root.splitDirection, .vertical)
	}

	func testMovePaneDoesNotLosePaneWhenTargetIsInvalid() {
		let state = CommandAreaState()
		guard let firstId = state.root.paneId else {
			return XCTFail("Expected first pane")
		}
		state.activePaneId = firstId
		state.splitActive(.horizontal)

		let before = leafIds(in: state.root)
		guard let secondId = before.first(where: { $0 != firstId }) else {
			return XCTFail("Expected second pane")
		}

		state.movePane(secondId, relativeTo: UUID(), position: .left)

		XCTAssertEqual(leafIds(in: state.root), before)
	}

	func testProjectLayoutStateCodableRoundTrip() throws {
		let state = ProjectLayoutState(
			commandAreaFraction: 0.62,
			showFileTree: false,
			fileTreeWidth: 288
		)

		let data = try JSONEncoder().encode(state)
		let decoded = try JSONDecoder().decode(ProjectLayoutState.self, from: data)

		XCTAssertEqual(decoded.commandAreaFraction, 0.62, accuracy: 0.0001)
		XCTAssertEqual(decoded.showFileTree, false)
		XCTAssertEqual(decoded.fileTreeWidth, 288, accuracy: 0.0001)
	}

	private func leafIds(in node: PaneNode) -> [UUID] {
		if let children = node.children {
			return children.flatMap { leafIds(in: $0) }
		}
		return node.paneId.map { [$0] } ?? []
	}

	// BELVE3 OSC → (paneId, tmuxSession, sessionId, status, message) を全 5 フィールド解析する。
	func testOSCTransportParsesBELVE3AllFields() {
		let transport = OSCAgentTransport()
		let exp = expectation(description: "onAgentStatus")
		var received: (String, String, String, String, String)?
		transport.onAgentStatus = { paneId, tmuxSession, sessionId, status, message in
			received = (paneId, tmuxSession, sessionId, status, message)
			exp.fulfill()
		}
		let osc = "\u{1b}]9;BELVE3:pane-1:belve-real:sid-9:running:hello world\u{07}"
		transport.scan(Data(osc.utf8))
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(received?.0, "pane-1")
		XCTAssertEqual(received?.1, "belve-real")
		XCTAssertEqual(received?.2, "sid-9")
		XCTAssertEqual(received?.3, "running")
		XCTAssertEqual(received?.4, "hello world")
	}

	// 旧 BELVE2 OSC は tmuxSession="" で渡る (権威ソース無し → Mac 側は session を作らない)。
	func testOSCTransportBELVE2YieldsEmptyTmuxSession() {
		let transport = OSCAgentTransport()
		let exp = expectation(description: "onAgentStatus")
		var received: (String, String, String, String, String)?
		transport.onAgentStatus = { paneId, tmuxSession, sessionId, status, message in
			received = (paneId, tmuxSession, sessionId, status, message)
			exp.fulfill()
		}
		let osc = "\u{1b}]9;BELVE2:pane-2:sid-3:completed:Done\u{07}"
		transport.scan(Data(osc.utf8))
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(received?.0, "pane-2")
		XCTAssertEqual(received?.1, "")
		XCTAssertEqual(received?.2, "sid-3")
		XCTAssertEqual(received?.3, "completed")
		XCTAssertEqual(received?.4, "Done")
	}

	// tmux 外 (tmuxSession="") + 非空 sid: 空 field が collapse せず正しく位置を保つ。
	func testOSCTransportBELVE3EmptyTmuxNonEmptySid() {
		let transport = OSCAgentTransport()
		let exp = expectation(description: "onAgentStatus")
		var received: (String, String, String, String, String)?
		transport.onAgentStatus = { paneId, tmuxSession, sessionId, status, message in
			received = (paneId, tmuxSession, sessionId, status, message)
			exp.fulfill()
		}
		let osc = "\u{1b}]9;BELVE3:pane-x::sid-1:running:hi\u{07}"
		transport.scan(Data(osc.utf8))
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(received?.0, "pane-x")
		XCTAssertEqual(received?.1, "")
		XCTAssertEqual(received?.2, "sid-1")
		XCTAssertEqual(received?.3, "running")
		XCTAssertEqual(received?.4, "hi")
	}

	// 非空 tmuxSession + 空 sid (= claude session_id 未確定): sid="" が collapse しない。
	func testOSCTransportBELVE3NonEmptyTmuxEmptySid() {
		let transport = OSCAgentTransport()
		let exp = expectation(description: "onAgentStatus")
		var received: (String, String, String, String, String)?
		transport.onAgentStatus = { paneId, tmuxSession, sessionId, status, message in
			received = (paneId, tmuxSession, sessionId, status, message)
			exp.fulfill()
		}
		let osc = "\u{1b}]9;BELVE3:pane-x:belve-x::running:hi\u{07}"
		transport.scan(Data(osc.utf8))
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(received?.0, "pane-x")
		XCTAssertEqual(received?.1, "belve-x")
		XCTAssertEqual(received?.2, "")
		XCTAssertEqual(received?.3, "running")
		XCTAssertEqual(received?.4, "hi")
	}

	// message に colon が含まれても maxSplits で intact に保たれる。
	func testOSCTransportBELVE3MessageWithColons() {
		let transport = OSCAgentTransport()
		let exp = expectation(description: "onAgentStatus")
		var received: (String, String, String, String, String)?
		transport.onAgentStatus = { paneId, tmuxSession, sessionId, status, message in
			received = (paneId, tmuxSession, sessionId, status, message)
			exp.fulfill()
		}
		let osc = "\u{1b}]9;BELVE3:pane-x:belve-x:sid-1:running:tool:Read:file\u{07}"
		transport.scan(Data(osc.utf8))
		wait(for: [exp], timeout: 1.0)

		XCTAssertEqual(received?.0, "pane-x")
		XCTAssertEqual(received?.1, "belve-x")
		XCTAssertEqual(received?.2, "sid-1")
		XCTAssertEqual(received?.3, "running")
		XCTAssertEqual(received?.4, "tool:Read:file")
	}
}
