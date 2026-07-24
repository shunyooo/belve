import Foundation

/// OSC payload を表示可能テキストに整形する共有ロジック。
/// `NotificationStore` (旧 identity/通知経路) と `AgentSessionStore` (新 session 実体)
/// の双方から使われる。ロジックはかつて NotificationStore.sanitizeMessage にあったもの。
///
/// 1. `\\n` (2 chars) → `\n` 復元 (hook 側 escape の inverse)
/// 2. OSC sequence を ESC + terminator 含めて除去 (= claude の window title 等)
/// 3. CSI escape codes を除去 (= 色 / カーソル制御)
/// 4. 制御文字を除去 (改行 / タブ / CR は保持)
/// 5. ESC 単独 + `]N;...` 残骸 / `]9;BELVE...` 混入を除去
enum AgentMessageSanitizer {
	static func sanitize(_ raw: String) -> String {
		var s = raw.replacingOccurrences(of: "\\n", with: "\n")
		// OSC: `\x1b]...\x07` or `\x1b]...\x1b\\` を ESC + terminator ごと strip。
		// ESC を残すと後続 filter で消えても `]N;...` が残るので、
		// ESC〜terminator を 1 まとめで削除する。
		s = s.replacingOccurrences(
			of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)",
			with: "",
			options: .regularExpression
		)
		// CSI: `\x1b[...A-Za-z`
		s = s.replacingOccurrences(
			of: "\u{1b}\\[[0-9;?]*[a-zA-Z]",
			with: "",
			options: .regularExpression
		)
		// 残った制御文字 (BEL / 単独 ESC / その他 0x00-0x08, 0x0b-0x1f) を除去。
		s = s.unicodeScalars.filter { c in
			let v = c.value
			if v == 0x09 || v == 0x0a || v == 0x0d { return true }
			return v >= 0x20
		}.map(String.init).joined()
		// ESC は消えてるが OSC の `]N;...BEL` 形式残骸 (= ESC stripped only) を defensive 削除。
		s = s.replacingOccurrences(
			of: "\\][0-9]+;[^\u{1b}\u{07}\\n]*",
			with: "",
			options: .regularExpression
		)
		// ネスト OSC: `]9;BELVE...` 以降は次 event 残骸 → drop
		if let r = s.range(of: "]9;BELVE") {
			s = String(s[..<r.lowerBound])
		}
		// 連続する空行を 1 つに圧縮 (= OSC strip 後の隙間が複数空行になりがち)
		s = s.replacingOccurrences(
			of: "\n{3,}",
			with: "\n\n",
			options: .regularExpression
		)
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
