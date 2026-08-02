import XCTest
@testable import Belve

/// ProjectLayoutState の旧単一ブラウザ → 複数ブラウザ (browserWindows) 移行のテスト。
final class BrowserWindowMigrationTests: XCTestCase {
	/// 旧形式 (browserURL/browserOpen) は 1 要素の browserWindows へ移行する。
	func testLegacySingleBrowserMigratesToOneWindow() throws {
		let json = Data("""
		{"browserURL":"http://localhost:3000","browserOpen":true,"browserThumbnail":false}
		""".utf8)
		let s = try JSONDecoder().decode(ProjectLayoutState.self, from: json)
		XCTAssertEqual(s.browserWindows.count, 1)
		XCTAssertEqual(s.browserWindows.first?.url, "http://localhost:3000")
		XCTAssertEqual(s.browserWindows.first?.open, true)
	}

	/// 旧 frame/viewport も引き継ぐ。
	func testLegacyFrameAndViewportCarryOver() throws {
		let json = Data("""
		{"browserURL":"https://x.test","browserFrame":{"x":10,"y":20,"width":800,"height":600},
		 "browserViewport":{"width":375,"height":667}}
		""".utf8)
		let s = try JSONDecoder().decode(ProjectLayoutState.self, from: json)
		XCTAssertEqual(s.browserWindows.count, 1)
		XCTAssertEqual(s.browserWindows.first?.frame?.width, 800)
		XCTAssertEqual(s.browserWindows.first?.viewport?.width, 375)
	}

	/// ブラウザを一度も使っていない旧データは空配列 (窓を作らない)。
	func testLegacyWithoutBrowserGivesEmpty() throws {
		let s = try JSONDecoder().decode(ProjectLayoutState.self, from: Data("{}".utf8))
		XCTAssertTrue(s.browserWindows.isEmpty)
	}

	/// 新形式は round-trip し、旧キーは書き出さない (dead field を残さない)。
	func testNewFormatRoundTripsAndDropsLegacyKeys() throws {
		let s = ProjectLayoutState()
		s.browserWindows = [
			BrowserWindowState(url: "https://a.com", open: true),
			BrowserWindowState(url: "https://b.com", open: false),
		]
		let data = try JSONEncoder().encode(s)
		let decoded = try JSONDecoder().decode(ProjectLayoutState.self, from: data)
		XCTAssertEqual(decoded.browserWindows.map(\.url), ["https://a.com", "https://b.com"])
		XCTAssertEqual(decoded.browserWindows.map(\.open), [true, false])

		let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertNil(dict["browserURL"], "旧キーは encode されない")
		XCTAssertNotNil(dict["browserWindows"])
	}

	/// 新旧両方のキーがある場合は新形式を優先する (移行済みデータの再読込)。
	func testNewFormatWinsOverLegacy() throws {
		let json = Data("""
		{"browserURL":"http://old","browserWindows":[{"id":"11111111-1111-1111-1111-111111111111","url":"http://new","open":true,"thumbnail":false}]}
		""".utf8)
		let s = try JSONDecoder().decode(ProjectLayoutState.self, from: json)
		XCTAssertEqual(s.browserWindows.count, 1)
		XCTAssertEqual(s.browserWindows.first?.url, "http://new")
	}
}
