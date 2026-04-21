import SwiftUI
import WebKit

/// Lightweight in-app browser for the preview area. Purpose-built for
/// debugging local / forwarded dev servers — not a general-purpose browser.
/// Shares state with the project's `ProjectLayoutState` so the URL survives
/// project switches and app restarts.
struct BrowserView: View {
	@ObservedObject var layoutState: ProjectLayoutState
	/// Active port forwards for this project — surfaces them in a "quick
	/// open" button so the user doesn't retype `http://localhost:3000` by
	/// hand every time.
	let portForwards: [PortForward]
	/// Called from the inline "避難" (dismiss) button or the keyboard shortcut.
	/// The window stays allocated; the caller can bring it back without
	/// losing page state.
	var onHide: (() -> Void)? = nil
	/// Called when the user asks for full close (not just hide).
	var onClose: (() -> Void)? = nil
	/// Called when the user clicks the thumbnail to restore full size.
	var onRestore: (() -> Void)? = nil
	/// True when the parent window has been shrunk to the thumbnail
	/// (避難) size. Hides chrome and overlays a click-catcher to expand.
	var isThumbnail: Bool = false
	/// viewport プリセット切替時にウィンドウのアスペクト比を仮想 viewport に
	/// 合わせるためのフック。`BrowserWindowManager.applyViewport` を呼ぶ。
	var onViewportChanged: ((CGSize?) -> Void)? = nil
	/// URL バーの実測高さを window resizer に伝えるためのフック。SwiftUI が
	/// 計測した正確な値を使うことで、small window 時の aspect ズレを解消する。
	var onURLBarHeightChanged: ((CGFloat) -> Void)? = nil

	@State private var urlFieldText: String = ""
	/// User-requested URL — only mutated by `commitURL()`. KVO observations
	/// of the WKWebView's URL update `urlFieldText` (the visible bar) but
	/// must not write here, otherwise SwiftUI re-renders trigger
	/// `updateNSView` which sees a stale request URL and re-loads, fighting
	/// the in-progress redirect chain (the infinite-reload bug).
	@State private var requestedURL: URL?
	/// `@StateObject` (not `@State`) so SwiftUI subscribes to the inner
	/// `@Published` properties — without this, `.onChange(of: navigationState.currentURL)`
	/// never fires because the parent view doesn't re-render on KVO updates,
	/// and the URL bar lags behind real navigation.
	@StateObject private var navigationState = NavigationState()
	@FocusState private var isURLFocused: Bool

	final class NavigationState: ObservableObject {
		@Published var canGoBack = false
		@Published var canGoForward = false
		@Published var isLoading = false
		@Published var progress: Double = 0
		/// True once the new page's commit has fired (≈ "first paint /
		/// content visible"). Used to flip the reload icon back to ⟳ as
		/// soon as the page is rendered, even if subresources (images,
		/// trackers) are still trickling in. Matches Chrome/Safari's UX.
		@Published var pageCommitted: Bool = true
		/// Mirrors `WKWebView.url` via KVO. BrowserView observes this with
		/// `.onChange` to keep the URL bar in sync — going through this
		/// `@Published` works more reliably than passing a closure into
		/// the NSViewRepresentable, which can capture stale `@State`.
		@Published var currentURL: URL?
	}

	var body: some View {
		ZStack(alignment: .bottomTrailing) {
			VStack(spacing: 0) {
				if !isThumbnail {
					VStack(spacing: 0) {
						urlBar
						Divider().overlay(Theme.borderSubtle)
					}
					// 実測高さを window resizer に流す → aspect 維持精度が
					// 画面サイズに依らず安定する。
					.background(GeometryReader { geo in
						Color.clear.preference(
							key: URLBarHeightPreferenceKey.self,
							value: geo.size.height
						)
					})
				}
				webContent
					.disabled(isThumbnail) // prevent stray clicks in thumbnail mode
			}
			.onPreferenceChange(URLBarHeightPreferenceKey.self) { h in
				onURLBarHeightChanged?(h)
			}
			// Click-catcher + expand hint when shown as a thumbnail.
			if isThumbnail {
				Button { onRestore?() } label: {
					ZStack(alignment: .topTrailing) {
						Color.clear
						Image(systemName: "arrow.up.left.and.arrow.down.right")
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(.white)
							.padding(6)
							.background(
								Circle()
									.fill(Color.black.opacity(0.55))
							)
							.padding(6)
					}
				}
				.buttonStyle(.plain)
				.help("Expand browser · ⌘⇧B")
			}
		}
		.background(Theme.surface)
		.onAppear {
			if urlFieldText.isEmpty {
				urlFieldText = layoutState.browserURL
			}
			if !layoutState.browserURL.isEmpty, requestedURL == nil {
				requestedURL = normaliseURL(layoutState.browserURL)
				navigationState.pageCommitted = false
			}
		}
		// Reflect the actual page URL (incl. SPA pushState) into the bar
		// whenever the user isn't editing it. Going through the published
		// `navigationState.currentURL` is more reliable than the closure-
		// based path which can capture stale @State references.
		.onChange(of: navigationState.currentURL) { _, new in
			guard let u = new, !isURLFocused else { return }
			let s = u.absoluteString
			if urlFieldText != s { urlFieldText = s }
		}
	}

	/// 仮想 viewport が指定されてるとき: WKWebView を仮想サイズで描画して、
	/// 親の利用可能領域に収まる scale で `.scaleEffect` を当てて視覚的に
	/// 縮小する。WKWebView 自身は仮想サイズで動いてるので CSS の media
	/// query は仮想 viewport ベースで評価される (Chrome DevTools のデバイス
	/// モードと同じ感覚)。
	@ViewBuilder
	private var webContent: some View {
		let webView = BrowserWebView(
			url: requestedURL,
			navigationState: navigationState,
			onURLCommitted: { committed in
				// Only mirror to the URL bar + persisted state. Do NOT touch
				// `requestedURL` — that's reserved for user-initiated loads.
				// Touching it here causes SwiftUI re-renders mid-redirect that
				// re-trigger the load (infinite-reload bug).
				urlFieldText = committed.absoluteString
				layoutState.browserURL = committed.absoluteString
			},
			// Thumbnail uses page-zoom so the whole page composition (not just
			// a tiny crop of the top-left) is visible at reduced size.
			pageZoom: isThumbnail ? 0.3 : 1.0
		)
		if let virtual = layoutState.browserViewport?.size, !isThumbnail {
			GeometryReader { geo in
				let scale = min(geo.size.width / virtual.width, geo.size.height / virtual.height)
				let scaledW = virtual.width * scale
				let scaledH = virtual.height * scale
				webView
					// WKWebView は仮想サイズで描画 (= media query は仮想 viewport 基準)
					.frame(width: virtual.width, height: virtual.height)
					// topLeading 起点でスケール → 視覚的な内容は (0,0)-(scaledW, scaledH)
					.scaleEffect(scale, anchor: .topLeading)
					// レイアウト足跡を視覚サイズに合わせる (scaleEffect は寸法を
					// 変えないので、明示的に書き直さないと中央寄せがずれる)。
					// alignment: .topLeading で内側 1920×1080 の左上を外側の左上に
					// 揃える → 視覚内容がそのまま外側を埋める。
					.frame(width: scaledW, height: scaledH, alignment: .topLeading)
					.clipped()
					// 残りのスペースはレターボックス。
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
			}
			.background(Color.black.opacity(0.6))
		} else {
			webView
		}
	}

	/// Viewport プリセット。表示順 (= ユーザーが選びそうな頻度順)。
	private static let viewportPresets: [(label: String, size: CGSize?)] = [
		("Native (window)", nil),
		("Mobile · 375 × 667", CGSize(width: 375, height: 667)),
		("Mobile L · 414 × 896", CGSize(width: 414, height: 896)),
		("Tablet · 768 × 1024", CGSize(width: 768, height: 1024)),
		("Desktop · 1280 × 800", CGSize(width: 1280, height: 800)),
		("Desktop L · 1440 × 900", CGSize(width: 1440, height: 900)),
		("FHD · 1920 × 1080", CGSize(width: 1920, height: 1080)),
	]

	private var viewportLabel: String {
		guard let v = layoutState.browserViewport?.size else { return "Native" }
		return "\(Int(v.width))×\(Int(v.height))"
	}

	private var urlBar: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				// Traffic-light-style controls: close (red) + hide (yellow).
				// Mimic macOS's native chrome rather than using it — we keep
				// a borderless window for the always-on-top panel behaviour,
				// but match the visual language so the affordance is obvious.
				trafficLight(color: Color(red: 0.92, green: 0.38, blue: 0.36), symbol: "xmark", help: "Close browser") {
					onClose?()
				}
				trafficLight(color: Color(red: 0.95, green: 0.73, blue: 0.22), symbol: "minus", help: "Hide (thumbnail)") {
					onHide?()
				}
				Button { navigationState.canGoBack ? navigate(.back) : () } label: {
					Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
				}
				.buttonStyle(.plain)
				.disabled(!navigationState.canGoBack)
				.foregroundStyle(navigationState.canGoBack ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))

				Button { navigationState.canGoForward ? navigate(.forward) : () } label: {
					Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
				}
				.buttonStyle(.plain)
				.disabled(!navigationState.canGoForward)
				.foregroundStyle(navigationState.canGoForward ? Theme.textSecondary : Theme.textTertiary.opacity(0.4))

				// アイコン状態に直結させる: X 表示中なら cancel、↻ 表示中なら reload。
				// `view.isLoading` を見て分岐する旧実装は、subresource (画像/
				// tracker) で isLoading が長く true になりがちな実ページで
				// 「↻ を押したのに reload にならず stop してしまう」事故が
				// 起きていた。
				Button {
					if navigationState.pageCommitted {
						navigate(.reload)
					} else {
						navigate(.cancel)
					}
				} label: {
					// Show stop-X only until first paint (didCommit). Beyond
					// that, treat the page as "loaded enough" — matches
					// Chrome/Safari which also flip the icon at commit even
					// if trackers/images are still streaming in.
					Image(systemName: !navigationState.pageCommitted ? "xmark" : "arrow.clockwise")
						.font(.system(size: 13, weight: .semibold))
						.frame(width: 18, height: 18)
				}
				.buttonStyle(.plain)
				.foregroundStyle(Theme.textPrimary)
				.help(navigationState.pageCommitted ? "Reload · ⌘R" : "Cancel load")

				TextField("localhost:3000 or https://…", text: $urlFieldText)
					.textFieldStyle(.plain)
					.font(.system(size: 11, design: .monospaced))
					.padding(.horizontal, 8)
					.padding(.vertical, 4)
					.background(RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceActive))
					.focused($isURLFocused)
					.onSubmit(commitURL)
					.layoutPriority(1)

				// Port forward chips inline next to the URL bar — each shows
				// the full local→remote mapping so the user can target a
				// specific forward without opening a menu.
				let enabled = portForwards.filter(\.enabled)
				if !enabled.isEmpty {
					ScrollView(.horizontal, showsIndicators: false) {
						HStack(spacing: 4) {
							ForEach(enabled) { forward in
								Button {
									urlFieldText = "http://localhost:\(forward.localPort)"
									commitURL()
								} label: {
									HStack(spacing: 3) {
										Text("\(forward.localPort)")
											.font(.system(size: 10, weight: .medium, design: .monospaced))
											.foregroundStyle(Theme.textPrimary)
										Text("→\(forward.remotePort)")
											.font(.system(size: 9, design: .monospaced))
											.foregroundStyle(Theme.textTertiary)
									}
									.padding(.horizontal, 6)
									.padding(.vertical, 3)
									.background(
										RoundedRectangle(cornerRadius: 3)
											.fill(Theme.surfaceActive)
									)
									.overlay(
										RoundedRectangle(cornerRadius: 3)
											.strokeBorder(Theme.borderSubtle, lineWidth: 1)
									)
								}
								.buttonStyle(.plain)
							}
						}
					}
					.frame(maxWidth: 220)
				}

				// Viewport size menu — Chrome DevTools のデバイスモード相当。
				// 仮想 viewport で WKWebView を描画して `.scaleEffect` で縮める
				// ので、media query は仮想サイズで評価される。
				Menu {
					ForEach(0..<Self.viewportPresets.count, id: \.self) { idx in
						let preset = Self.viewportPresets[idx]
						Button {
							layoutState.browserViewport = preset.size.map { StoredViewport($0) }
							// ウィンドウのアスペクト比も viewport に合わせて
							// 即座に整形 (= レターボックスが出ない)。
							onViewportChanged?(preset.size)
						} label: {
							let isCurrent = (preset.size.map { StoredViewport($0) }) == layoutState.browserViewport
							Label(preset.label, systemImage: isCurrent ? "checkmark" : "")
						}
					}
				} label: {
					HStack(spacing: 3) {
						Image(systemName: "rectangle.split.2x1")
							.font(.system(size: 10))
						Text(viewportLabel)
							.font(.system(size: 10, design: .monospaced))
					}
					.foregroundStyle(Theme.textSecondary)
					.padding(.horizontal, 6).padding(.vertical, 3)
					.background(
						RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceActive)
					)
					.overlay(
						RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderSubtle, lineWidth: 1)
					)
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				.fixedSize()
				.help("Viewport size (for responsive testing)")
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.overlay(alignment: .bottom) {
			// Progress bar mirrors the icon: hide as soon as first paint
			// happens. Subresource loading after that is invisible work.
			GeometryReader { geo in
				Rectangle()
					.fill(Theme.accent)
					.frame(width: geo.size.width * CGFloat(navigationState.progress))
					.opacity(navigationState.pageCommitted ? 0 : 1)
					.animation(.easeOut(duration: 0.2), value: navigationState.progress)
					.animation(.easeOut(duration: 0.3), value: navigationState.pageCommitted)
			}
			.frame(height: 2)
		}
		// The entire URL-bar strip doubles as the window-drag region (there's
		// no titlebar). Child controls still intercept their own clicks.
		.background(WindowDragRegion())
	}

	/// Traffic-light-style 12pt circle button. Color indicates purpose; the
	/// symbol shows on hover (matches macOS chrome feel).
	private func trafficLight(color: Color, symbol: String, help: String, action: @escaping () -> Void) -> some View {
		TrafficLightButton(color: color, symbol: symbol, action: action)
			.help(help)
	}

	enum NavAction { case back, forward, reload, cancel }
	private func navigate(_ action: NavAction) {
		// state の更新は coordinator 側に集約 (ボタン経路と Cmd+R 経路で
		// 挙動を揃えるため)。ここは notification を投げるだけ。
		NotificationCenter.default.post(
			name: .belveBrowserNav, object: nil, userInfo: ["action": action]
		)
	}

	private func commitURL() {
		let trimmed = urlFieldText.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty else { return }
		guard let u = normaliseURL(trimmed) else {
			NSLog("[Belve][browser] commitURL: normalise failed text=%@", trimmed)
			return
		}
		NSLog("[Belve][browser] commitURL url=%@", u.absoluteString)
		requestedURL = u
		navigationState.pageCommitted = false
		urlFieldText = u.absoluteString
		layoutState.browserURL = u.absoluteString
		isURLFocused = false
	}

	/// Accept naked hosts like `localhost:3000` and `example.com/path` — assume
	/// http:// for localhost (dev servers almost never ship HTTPS locally) and
	/// https:// for everything else.
	private func normaliseURL(_ text: String) -> URL? {
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		if trimmed.isEmpty { return nil }
		if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
			return URL(string: trimmed)
		}
		let prefix = (trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") || trimmed.hasPrefix("0.0.0.0"))
			? "http://"
			: "https://"
		return URL(string: prefix + trimmed)
	}
}

// MARK: - WKWebView wrapper

private struct BrowserWebView: NSViewRepresentable {
	let url: URL?
	@ObservedObject var navigationState: BrowserView.NavigationState
	var onURLCommitted: (URL) -> Void
	/// Page zoom factor — 1.0 for normal viewing, ~0.25 when the window has
	/// been shrunk to thumbnail mode so the entire page composition stays
	/// visible instead of just the top-left corner.
	var pageZoom: CGFloat = 1.0

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		// Persist cookies / localStorage per-app so OAuth sign-in flows stick
		// across project switches and app restarts.
		config.websiteDataStore = .default()
		config.preferences.javaScriptCanOpenWindowsAutomatically = false
		let view = WKWebView(frame: .zero, configuration: config)
		view.setValue(true, forKey: "inspectable") // Safari DevTools reachable
		view.allowsBackForwardNavigationGestures = true
		view.navigationDelegate = context.coordinator
		view.uiDelegate = context.coordinator
		context.coordinator.webView = view
		context.coordinator.observeProperties(view)
		return view
	}

	func updateNSView(_ view: WKWebView, context: Context) {
		context.coordinator.navigationState = navigationState
		context.coordinator.onURLCommitted = onURLCommitted
		if abs(view.pageZoom - pageZoom) > 0.001 {
			view.pageZoom = pageZoom
		}
		NSLog("[Belve][browser] updateNSView url=%@ last=%@",
		      url?.absoluteString ?? "nil",
		      context.coordinator.lastRequestedURL?.absoluteString ?? "nil")
		// Only load when the *requested* URL changed — comparing against
		// `view.url` would revert the page after every in-page navigation
		// (link click, pushState), because BrowserView re-renders on each
		// KVO `.url` update and `requestedURL` still holds the original.
		if let url, url != context.coordinator.lastRequestedURL {
			NSLog("[Belve][browser] view.load %@", url.absoluteString)
			context.coordinator.lastRequestedURL = url
			view.load(URLRequest(url: url))
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator(navigationState: navigationState, onURLCommitted: onURLCommitted)
	}

	final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
		weak var webView: WKWebView?
		var navigationState: BrowserView.NavigationState
		var onURLCommitted: (URL) -> Void
		/// Last URL BrowserView asked us to load. Used to distinguish a real
		/// new request from `updateNSView` re-runs caused by SwiftUI
		/// re-rendering after KVO `.url` updates. Without this, every
		/// in-page navigation gets reverted back to the requested URL.
		var lastRequestedURL: URL?
		private var navMonitor: Any?

		init(navigationState: BrowserView.NavigationState, onURLCommitted: @escaping (URL) -> Void) {
			self.navigationState = navigationState
			self.onURLCommitted = onURLCommitted
			super.init()
			navMonitor = NotificationCenter.default.addObserver(
				forName: .belveBrowserNav, object: nil, queue: .main
			) { [weak self] notif in
				guard let self, let view = self.webView else { return }
				switch notif.userInfo?["action"] as? BrowserView.NavAction {
				case .back:
					self.navigationState.pageCommitted = false
					view.goBack()
				case .forward:
					self.navigationState.pageCommitted = false
					view.goForward()
				case .reload:
					// アイコンを即 X に飛ばす。Cmd+R 経路は `navigate()` を
					// 通らないので、ここで state を同期しないとアイコンが
					// ↻ のまま残る (didCommit 後に true へ戻る本来の挙動)。
					self.navigationState.pageCommitted = false
					self.navigationState.isLoading = true
					self.navigationState.progress = 0.05
					NSLog("[Belve][browser] reload view.url=%@ last=%@",
					      view.url?.absoluteString ?? "nil",
					      self.lastRequestedURL?.absoluteString ?? "nil")
					if view.url != nil {
						view.reload()
					} else if let last = self.lastRequestedURL {
						// 初回ロード前の reload (cmd+r などで誤発火) は
						// 直接 last requested URL を読みに行く。
						view.load(URLRequest(url: last))
					}
				case .cancel:
					view.stopLoading()
					self.navigationState.pageCommitted = true
					self.navigationState.isLoading = false
					self.navigationState.progress = 0
				case .none: break
				}
			}
		}

		deinit {
			if let m = navMonitor { NotificationCenter.default.removeObserver(m) }
		}

		private var kvoTokens: [NSKeyValueObservation] = []
		func observeProperties(_ view: WKWebView) {
			kvoTokens.append(view.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
				DispatchQueue.main.async { self?.navigationState.canGoBack = change.newValue ?? false }
			})
			kvoTokens.append(view.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
				DispatchQueue.main.async { self?.navigationState.canGoForward = change.newValue ?? false }
			})
			kvoTokens.append(view.observe(\.isLoading, options: [.new]) { [weak self] _, change in
				DispatchQueue.main.async { self?.navigationState.isLoading = change.newValue ?? false }
			})
			kvoTokens.append(view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
				DispatchQueue.main.async { self?.navigationState.progress = change.newValue ?? 0 }
			})
			// Track `.url` for SPA navigations (pushState / replaceState / hash
			// changes) — those don't fire `didCommit`, so the URL bar falls
			// behind without KVO here. Surface the change via the
			// observable `navigationState.currentURL`; BrowserView mirrors
			// that into the URL bar text via `.onChange`.
			kvoTokens.append(view.observe(\.url, options: [.new]) { [weak self] _, change in
				guard let u = change.newValue ?? nil else { return }
				DispatchQueue.main.async {
					self?.navigationState.currentURL = u
					self?.onURLCommitted(u)
				}
			})
		}

		func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
			NSLog("[Belve][browser] didCommit url=%@", webView.url?.absoluteString ?? "nil")
			if let u = webView.url {
				navigationState.currentURL = u
				onURLCommitted(u)
			}
			// Page has rendered — flip the reload affordance back even if
			// subresources / ads / pixel trackers keep `isLoading` true.
			navigationState.pageCommitted = true
		}

		func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
			NSLog("[Belve][browser] didStart url=%@", webView.url?.absoluteString ?? "nil")
		}
		// Note: we deliberately do *not* set `pageCommitted = false` on
		// `didStartProvisionalNavigation`. Pages that auto-refresh (HMR,
		// meta refresh, JS reload) would otherwise re-trigger our
		// "loading…" UI repeatedly. User-initiated reloads / URL submits
		// reset the state explicitly via the actions below.

		// Belt-and-suspenders: KVO on `.isLoading` *should* fire false on
		// completion, but if the observer is delayed or coalesces away the
		// final transition, the reload icon stays as the stop-X. These
		// delegate callbacks force the state back to idle.
		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			navigationState.isLoading = false
			navigationState.progress = 1
			navigationState.pageCommitted = true
		}
		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			NSLog("[Belve][browser] didFail url=%@ error=%@", webView.url?.absoluteString ?? "nil", error.localizedDescription)
			navigationState.isLoading = false
			navigationState.progress = 0
			navigationState.pageCommitted = true
		}
		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			NSLog("[Belve][browser] didFailProvisional url=%@ error=%@", webView.url?.absoluteString ?? "nil", error.localizedDescription)
			navigationState.isLoading = false
			navigationState.progress = 0
			navigationState.pageCommitted = true
		}

		// Accept self-signed certs from localhost / private IPs — dev servers
		// rarely ship valid certs and blocking hurts more than it helps here.
		func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge,
					 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
			guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
				  let trust = challenge.protectionSpace.serverTrust else {
				completionHandler(.performDefaultHandling, nil)
				return
			}
			let host = challenge.protectionSpace.host
			if host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("172.") {
				completionHandler(.useCredential, URLCredential(trust: trust))
			} else {
				completionHandler(.performDefaultHandling, nil)
			}
		}
	}
}

// MARK: - Traffic-light-style button

/// 12pt colored circle that reveals its symbol on hover. Sized + spaced to
/// match native macOS traffic-light buttons so users reach for it
/// instinctively.
private struct TrafficLightButton: View {
	let color: Color
	let symbol: String
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		Button(action: action) {
			ZStack {
				Circle()
					.fill(color)
					.frame(width: 12, height: 12)
					.overlay(
						Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
					)
				if hovering {
					Image(systemName: symbol)
						.font(.system(size: 8, weight: .bold))
						.foregroundStyle(Color.black.opacity(0.65))
				}
			}
		}
		.buttonStyle(.plain)
		.onHover { hovering = $0 }
	}
}

// MARK: - Draggable region (replaces the native titlebar)

/// A transparent area that, when clicked and dragged, moves the containing
/// window. `NSWindow.performDrag(with:)` handles the live tracking + the
/// snap-to-edge behaviour you'd expect from the native titlebar.
private struct WindowDragRegion: NSViewRepresentable {
	func makeNSView(context: Context) -> DragNSView {
		DragNSView()
	}

	func updateNSView(_ nsView: DragNSView, context: Context) {}

	class DragNSView: NSView {
		override func mouseDown(with event: NSEvent) {
			window?.performDrag(with: event)
		}
		override func resetCursorRects() {
			addCursorRect(bounds, cursor: .openHand)
		}
	}
}

extension Notification.Name {
	static let belveBrowserNav = Notification.Name("belveBrowserNav")
}

/// URL バー (+ Divider) の実測高さを子から親に伝える。
private struct URLBarHeightPreferenceKey: PreferenceKey {
	static var defaultValue: CGFloat = 30
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}
