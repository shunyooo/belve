import XCTest
@testable import Belve

final class WorktreeServiceTests: XCTestCase {
	/// 標準的な複数 worktree。先頭が main、ブランチが refs/heads/ 除去で取れる。
	func testParsesMainAndBranches() {
		let porcelain = """
		worktree /home/u/src/app
		HEAD abc123
		branch refs/heads/main

		worktree /home/u/src/app/.claude/worktrees/agent-x/sandbox/feat
		HEAD def456
		branch refs/heads/feature-x
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws.count, 2)
		XCTAssertEqual(ws[0].path, "/home/u/src/app")
		XCTAssertEqual(ws[0].branch, "main")
		XCTAssertEqual(ws[0].head, "abc123")
		XCTAssertTrue(ws[0].isMain)
		XCTAssertFalse(ws[0].isClaudeCreated)
		XCTAssertFalse(ws[1].isMain)
		XCTAssertEqual(ws[1].branch, "feature-x")
	}

	/// Claude 製 (.claude/worktrees 配下) のマーク。
	func testMarksClaudeCreated() {
		let porcelain = """
		worktree /repo
		branch refs/heads/main

		worktree /repo/.claude/worktrees/agent-abc/sandbox/run1
		branch refs/heads/wip

		worktree /repo/other/manual-wt
		branch refs/heads/manual
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws.count, 3)
		XCTAssertFalse(ws[0].isClaudeCreated)
		XCTAssertTrue(ws[1].isClaudeCreated, ".claude/worktrees 配下は Claude 製")
		XCTAssertFalse(ws[2].isClaudeCreated, "他の worktree は非マーク")
	}

	/// detached HEAD: branch nil、label はパス末尾にフォールバック。
	func testDetachedHasNoBranchAndPathLabel() {
		let porcelain = """
		worktree /repo
		branch refs/heads/main

		worktree /repo/detached-wt
		HEAD 9f9f9f
		detached
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws.count, 2)
		XCTAssertNil(ws[1].branch)
		XCTAssertTrue(ws[1].isDetached)
		XCTAssertEqual(ws[1].displayLabel, "repo/detached-wt")
	}

	/// bare リポジトリレコード: bare フラグ、ブランチ無し。
	func testBareRepo() {
		let porcelain = """
		worktree /repo/bare.git
		bare
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws.count, 1)
		XCTAssertTrue(ws[0].isBare)
		XCTAssertNil(ws[0].branch)
		XCTAssertEqual(ws[0].displayLabel, "(bare)")
	}

	/// locked / prunable 行がレコード境界を壊さない。
	func testLockedAndPrunableDoNotBreakRecords() {
		let porcelain = """
		worktree /repo
		branch refs/heads/main

		worktree /repo/locked-wt
		HEAD aaa
		branch refs/heads/locked-branch
		locked being worked on
		prunable gitdir file points to non-existent location
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws.count, 2)
		XCTAssertEqual(ws[1].branch, "locked-branch")
		XCTAssertTrue(ws[1].isLocked)
	}

	/// 絶対パスがそのまま保持される (相対化されない)。
	func testAbsolutePathsPreserved() {
		let porcelain = """
		worktree /home/kawamoto/src/clay-api-seto
		branch refs/heads/main
		"""
		let ws = WorktreeService.parse(porcelain)
		XCTAssertEqual(ws[0].path, "/home/kawamoto/src/clay-api-seto")
	}

	/// 空文字列は空配列。
	func testEmptyIsEmpty() {
		XCTAssertTrue(WorktreeService.parse("").isEmpty)
	}

	/// runner が nil を返す (git 無し / repo でない) → list は空配列。
	func testListReturnsEmptyWhenRunnerNil() {
		let svc = WorktreeService(runCommand: { _ in nil })
		XCTAssertTrue(svc.list(effectivePath: "/repo").isEmpty)
	}

	/// list は git -C <path> worktree list --porcelain を呼ぶ。
	func testListInvokesPorcelainCommand() {
		var seen = ""
		let svc = WorktreeService(runCommand: { cmd in
			seen = cmd
			return "worktree /repo\nbranch refs/heads/main\n"
		})
		let ws = svc.list(effectivePath: "/repo")
		XCTAssertTrue(seen.contains("worktree list --porcelain"))
		XCTAssertTrue(seen.contains("'/repo'"))
		XCTAssertEqual(ws.count, 1)
		XCTAssertTrue(ws[0].isMain)
	}
}
