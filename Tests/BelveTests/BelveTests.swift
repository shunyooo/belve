import XCTest
@testable import Belve

final class BelveTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }

	func testAgentEventFileMonitorBuffersPartialLines() {
		let monitor = AgentEventFileMonitor()
		let first = monitor.consume("{\"paneId\":\"p1\"")
		XCTAssertTrue(first.isEmpty)

		let second = monitor.consume(",\"status\":\"running\",\"message\":\"hello\"}\n")
		XCTAssertEqual(second, ["{\"paneId\":\"p1\",\"status\":\"running\",\"message\":\"hello\"}"])
	}

	func testAgentEventFileMonitorParsesMultipleCompleteLines() {
		let monitor = AgentEventFileMonitor()
		let lines = monitor.consume("{\"paneId\":\"p1\",\"status\":\"running\",\"message\":\"a\"}\n{\"paneId\":\"p2\",\"status\":\"waiting\",\"message\":\"b\"}\n")
		XCTAssertEqual(
			lines,
			[
				"{\"paneId\":\"p1\",\"status\":\"running\",\"message\":\"a\"}",
				"{\"paneId\":\"p2\",\"status\":\"waiting\",\"message\":\"b\"}",
			]
		)
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
}
