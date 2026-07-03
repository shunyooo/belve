import Foundation
import WebKit

/// Markdown preview の `<img>` を remote (SSH / container) / local 問わず表示する
/// ための custom URL scheme handler。
///
/// 経緯: markdown preview は `loadHTMLString(baseURL: nil)` で HTML を流し込む
/// ため相対 / 絶対パスの画像 src を解決できず、かつ画像本体は remote に在るので
/// WebView から直接取得できなかった。JS 側で `<img src>` を
/// `belve-img://x/<percent-encoded-absolute-path>` に書き換え、この handler が
/// provider.downloadFile 経由で bytes を取得して応答する。
///
/// data: URI inline (= 全画像を base64 で HTML に埋める) 案と比べ、
///   - lazy load (画面に出る img だけ取得)
///   - WebView が response を自動キャッシュ → 編集の re-render で再取得しない
///   - HTML 肥大なし
/// の利点がある。scheme registration は WKWebViewConfiguration で 1 回。
///
/// Threading: WKURLSchemeTask の各メソッドは開始と同じ順序で呼ぶ必要がある。
/// download は blocking (scp / docker cp) なので background で実行し、完了後に
/// main へ戻して応答する。`stop(_:)` で cancel されたタスクへ応答すると WebKit が
/// 例外を投げるため、live task 集合を lock 付きで管理して cancel 済みは skip する。
final class BelveImageSchemeHandler: NSObject, WKURLSchemeHandler {
	static let scheme = "belve-img"

	private let provider: any WorkspaceProvider
	private var liveTasks = Set<ObjectIdentifier>()
	private let lock = NSLock()

	init(provider: any WorkspaceProvider) {
		self.provider = provider
	}

	func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
		let id = ObjectIdentifier(urlSchemeTask)
		lock.withLock { _ = liveTasks.insert(id) }

		guard let absPath = Self.decodePath(from: urlSchemeTask.request.url) else {
			finish(urlSchemeTask, id: id, failWith: "bad url")
			return
		}

		let provider = self.provider
		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			guard let self else { return }
			// download を temp file 経由で取得 (provider は binary-safe な file 取得 API
			// しか持たないため)。取得後 bytes を読み出す。
			let ext = (absPath as NSString).pathExtension
			let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("belve-md-img")
			try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
			let tmpFile = tmpDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
			defer { try? FileManager.default.removeItem(at: tmpFile) }

			let ok = provider.downloadFile(remotePath: absPath, to: tmpFile)
			let data = ok ? (try? Data(contentsOf: tmpFile)) : nil

			DispatchQueue.main.async {
				guard let data else {
					self.finish(urlSchemeTask, id: id, failWith: "download failed: \(absPath)")
					return
				}
				// cancel 済みなら何もしない (WebKit 例外回避)。
				guard self.lock.withLock({ self.liveTasks.contains(id) }) else { return }
				let response = URLResponse(
					url: urlSchemeTask.request.url!,
					mimeType: Self.mimeType(forExtension: ext),
					expectedContentLength: data.count,
					textEncodingName: nil
				)
				urlSchemeTask.didReceive(response)
				urlSchemeTask.didReceive(data)
				urlSchemeTask.didFinish()
				self.lock.withLock { _ = self.liveTasks.remove(id) }
			}
		}
	}

	func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
		lock.withLock { _ = liveTasks.remove(ObjectIdentifier(urlSchemeTask)) }
	}

	private func finish(_ task: WKURLSchemeTask, id: ObjectIdentifier, failWith reason: String) {
		guard lock.withLock({ liveTasks.contains(id) }) else { return }
		NSLog("[Belve][md-img] %@", reason)
		task.didFailWithError(NSError(domain: "BelveImageScheme", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]))
		lock.withLock { _ = liveTasks.remove(id) }
	}

	/// `belve-img://x/<percent-encoded-absolute-path>` から絶対パスを復元する。
	static func decodePath(from url: URL?) -> String? {
		guard let url else { return nil }
		let s = url.absoluteString
		let prefix = "\(scheme)://x/"
		guard s.hasPrefix(prefix) else { return nil }
		let encoded = String(s.dropFirst(prefix.count))
		// 絶対 (/...) / 相対 (docs/...) 両方許可。相対は provider.downloadFile が
		// remote workspace (RWS / effectivePath) 基準で解決する。
		guard let decoded = encoded.removingPercentEncoding, !decoded.isEmpty else { return nil }
		return decoded
	}

	private static func mimeType(forExtension ext: String) -> String {
		switch ext.lowercased() {
		case "png": return "image/png"
		case "jpg", "jpeg": return "image/jpeg"
		case "gif": return "image/gif"
		case "svg": return "image/svg+xml"
		case "webp": return "image/webp"
		case "bmp": return "image/bmp"
		case "ico": return "image/x-icon"
		case "avif": return "image/avif"
		case "tiff", "tif": return "image/tiff"
		default: return "application/octet-stream"
		}
	}
}
