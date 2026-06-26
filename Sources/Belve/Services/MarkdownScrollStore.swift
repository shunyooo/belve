import Foundation

/// Markdown ファイルの Edit ↔ Preview トグル時に scroll 位置を引き継ぐための
/// 軽量 in-memory ストア。
///
/// MarkdownPreviewView (= read-only HTML) と CodeEditorView (= raw text 編集) は
/// 別 WKWebView なので、トグルすると片側の WebView は破棄されて scroll 状態が
/// 消える。両 View が連続して current scroll % をここに書き込み、mount 時に
/// 読み戻す事で「どこを見ていたか」を維持する。
///
/// 値の意味は `scrollTop / (scrollHeight - clientHeight)` で 0...1 に正規化した
/// もの。CodeMirror と HTML preview で行マッピングは違うが、% は両方で取れて
/// 「だいたい同じ位置」を再現するには十分な精度 (= line ベースの精密同期は別途)。
///
/// Persistence: 現在は process-memory のみ (Belve.app 再起動でクリア)。
/// 必要なら UserDefaults / disk JSON に移行可。
final class MarkdownScrollStore: @unchecked Sendable {
	static let shared = MarkdownScrollStore()

	private var percents: [String: CGFloat] = [:]
	private let lock = NSLock()

	private init() {}

	func get(for path: String) -> CGFloat {
		lock.withLock { percents[path] ?? 0 }
	}

	func set(_ percent: CGFloat, for path: String) {
		let clamped = max(0, min(1, percent))
		lock.withLock { percents[path] = clamped }
	}
}
