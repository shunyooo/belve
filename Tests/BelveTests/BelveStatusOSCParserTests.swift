import XCTest
@testable import Belve

final class BelveStatusOSCParserTests: XCTestCase {
	private let prefix = "\u{1b}]9;belve-status;"

	private func d(_ s: String) -> Data { Data(s.utf8) }

	func testPlainOutputPassesThroughUnchanged() {
		let r = BelveStatusOSCParser.extract(from: d("hello world\n"))
		XCTAssertTrue(r.messages.isEmpty)
		XCTAssertEqual(r.outputData, d("hello world\n"))
		XCTAssertTrue(r.trailingData.isEmpty)
	}

	func testExtractsCompleteStatusMessageAndStripsItFromOutput() {
		let r = BelveStatusOSCParser.extract(from: d("A\(prefix)Connecting\u{07}B"))
		XCTAssertEqual(r.messages, ["Connecting"])
		XCTAssertEqual(r.outputData, d("AB"))
		XCTAssertTrue(r.trailingData.isEmpty)
	}

	func testSplitAcrossChunksIsBufferedThenMatched() {
		// チャンク1: プレフィックス途中で切れる → trailing に保持、output は先頭のみ。
		let r1 = BelveStatusOSCParser.extract(from: d("X\(prefix)Con"))
		XCTAssertTrue(r1.messages.isEmpty)
		XCTAssertEqual(r1.outputData, d("X"))
		XCTAssertFalse(r1.trailingData.isEmpty)
		// チャンク2: trailing + 続き (BEL 到達) → メッセージ確定。
		let r2 = BelveStatusOSCParser.extract(from: r1.trailingData + d("nected\u{07}Y"))
		XCTAssertEqual(r2.messages, ["Connected"])
		XCTAssertEqual(r2.outputData, d("Y"))
		XCTAssertTrue(r2.trailingData.isEmpty)
	}

	/// 回帰テスト (100GB クラッシュ): BEL が永久に来ないプレフィックス以降が
	/// 無限に trailing へ溜まらないこと。上限超過で literal 出力に切り替わり trailing は空。
	func testDanglingPrefixDoesNotGrowUnbounded() {
		let cap = 64
		// プレフィックス + BEL 無しで cap を超える大量データ。
		let flood = String(repeating: "x", count: cap * 4)
		let r = BelveStatusOSCParser.extract(from: d("\(prefix)\(flood)"), maxPendingBytes: cap)
		XCTAssertTrue(r.messages.isEmpty, "BEL 無しなのでメッセージは確定しない")
		XCTAssertTrue(r.trailingData.isEmpty, "上限超過で保持を打ち切り、無限膨張しない")
		// 吐き出された literal 出力にプレフィックス以降が含まれる (取りこぼさない)。
		XCTAssertEqual(r.outputData, d("\(prefix)\(flood)"))
	}

	/// 上限直下ではまだ BEL を待って保持する (正当な split メッセージを壊さない)。
	func testUnderCapStillBuffersForLaterTerminator() {
		let cap = 4096
		let r = BelveStatusOSCParser.extract(from: d("\(prefix)short"), maxPendingBytes: cap)
		XCTAssertTrue(r.messages.isEmpty)
		XCTAssertFalse(r.trailingData.isEmpty, "上限未満なので BEL 待ちで保持")
		XCTAssertTrue(r.outputData.isEmpty)
	}

	func testMultipleMessagesInOneChunk() {
		let r = BelveStatusOSCParser.extract(from: d("\(prefix)one\u{07}mid\(prefix)two\u{07}end"))
		XCTAssertEqual(r.messages, ["one", "two"])
		XCTAssertEqual(r.outputData, d("midend"))
		XCTAssertTrue(r.trailingData.isEmpty)
	}
}
