import XCTest
@testable import Belve

/// RemoteFolderWatcher.plan (純粋な watch 差分計算) のテスト。RPC は伴わない。
final class RemoteFolderWatcherTests: XCTestCase {
	func testAddsNewDesiredPaths() {
		let (toAdd, toRemove) = RemoteFolderWatcher.plan(
			current: [:], desired: ["/repo/a", "/repo/b"], maxWatches: 64
		)
		XCTAssertEqual(Set(toAdd), ["/repo/a", "/repo/b"])
		XCTAssertTrue(toRemove.isEmpty)
	}

	func testRemovesDroppedPaths() {
		let (toAdd, toRemove) = RemoteFolderWatcher.plan(
			current: ["/repo/a": "w1", "/repo/b": "w2"],
			desired: ["/repo/a"], maxWatches: 64
		)
		XCTAssertTrue(toAdd.isEmpty)
		XCTAssertEqual(toRemove.map(\.path), ["/repo/b"])
		XCTAssertEqual(toRemove.first?.watchId, "w2")
	}

	func testNoChangeWhenDesiredMatchesCurrent() {
		let (toAdd, toRemove) = RemoteFolderWatcher.plan(
			current: ["/repo/a": "w1"], desired: ["/repo/a"], maxWatches: 64
		)
		XCTAssertTrue(toAdd.isEmpty)
		XCTAssertTrue(toRemove.isEmpty)
	}

	/// .git 配下は監視対象にしない (self-trigger loop 防止)。
	func testExcludesGitPaths() {
		let (toAdd, _) = RemoteFolderWatcher.plan(
			current: [:],
			desired: ["/repo/src", "/repo/.git", "/repo/.git/hooks", "/repo/a/.git"],
			maxWatches: 64
		)
		XCTAssertEqual(toAdd, ["/repo/src"])
	}

	/// 上限を超える分は張らない (inotify instance 枯渇の防止)。
	func testRespectsMaxWatches() {
		let desired = Set((0..<10).map { "/repo/d\($0)" })
		let (toAdd, _) = RemoteFolderWatcher.plan(current: [:], desired: desired, maxWatches: 3)
		XCTAssertEqual(toAdd.count, 3)
	}

	/// 解除で空いた枠は追加に再利用できる (上限は「解除後の残数」に対して効く)。
	func testRemovedSlotsFreeBudget() {
		// 上限3、現在3件 (a,b,c)。desired は a + 新規 d,e,f → b,c を解除して 2 枠空き +
		// 元々 a が残るので残数1、budget = 3-1 = 2 → d,e,f のうち 2 件だけ add。
		let (toAdd, toRemove) = RemoteFolderWatcher.plan(
			current: ["/a": "w1", "/b": "w2", "/c": "w3"],
			desired: ["/a", "/d", "/e", "/f"],
			maxWatches: 3
		)
		XCTAssertEqual(Set(toRemove.map(\.path)), ["/b", "/c"])
		XCTAssertEqual(toAdd.count, 2)
	}

	func testEmptyDesiredRemovesAll() {
		let (toAdd, toRemove) = RemoteFolderWatcher.plan(
			current: ["/a": "w1", "/b": "w2"], desired: [], maxWatches: 64
		)
		XCTAssertTrue(toAdd.isEmpty)
		XCTAssertEqual(Set(toRemove.map(\.path)), ["/a", "/b"])
	}
}
