import AppKit
import SwiftUI

/// Borderless NSPanel that's still allowed to become key + main. Required so
/// clicking the browser actually puts it in `NSApp.keyWindow` — without this,
/// global shortcuts like Cmd+R can't route to the focused browser.
final class FloatingBrowserPanel: NSPanel {
	override var canBecomeKey: Bool { true }
	override var canBecomeMain: Bool { true }
}

/// 仮想 viewport を厳密に維持するための window delegate。
///
/// `contentAspectRatio` だけだと「URL バー高さは固定 pixel / web 領域は可変」と
/// いう構造から、ウィンドウサイズによって web 領域の aspect が微妙にズレる
/// (特に小さい時)。`windowWillResize` でユーザー操作を傍受して、毎回
/// `web 領域 = virtual aspect` になるよう高さを上書きする。
@MainActor
final class BrowserWindowResizer: NSObject, NSWindowDelegate {
	var virtualViewport: CGSize?
	/// URL バーの実測高さ。SwiftUI 側から PreferenceKey で更新される。
	/// 初期値は概算 30pt — 計測前に resize しても致命的なズレにならない値。
	var urlBarHeight: CGFloat = 30

	nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
		MainActor.assumeIsolated {
			guard let v = virtualViewport, v.width > 0, v.height > 0 else {
				return frameSize
			}
			let webHeight = frameSize.width * v.height / v.width
			return NSSize(width: frameSize.width, height: webHeight + urlBarHeight)
		}
	}
}

/// Thin host that subscribes to `BrowserWindowManager` so `BrowserView`
/// re-renders when the window transitions between full-size and thumbnail
/// modes. Putting the `@ObservedObject` here keeps `BrowserWindowManager`
/// decoupled from SwiftUI's lifecycle.
private struct BrowserHostView: View {
	@ObservedObject var manager: BrowserWindowManager
	let projectId: UUID
	@ObservedObject var layoutState: ProjectLayoutState
	let portForwards: [PortForward]

	var body: some View {
		BrowserView(
			layoutState: layoutState,
			portForwards: portForwards,
			onHide: { manager.hide(projectId: projectId) },
			onClose: { manager.close(projectId: projectId) },
			onRestore: { manager.restore(projectId: projectId) },
			isThumbnail: manager.thumbnails.contains(projectId),
			onViewportChanged: { viewport in
				manager.applyViewport(projectId: projectId, viewport: viewport)
			},
			onURLBarHeightChanged: { h in
				manager.updateURLBarHeight(projectId: projectId, height: h)
			}
		)
	}
}

/// Spawns standalone browser windows tied to a project. One window per project
/// at most — re-invocation for the same project just brings the existing
/// window forward. Keeps state on the project's `ProjectLayoutState` so URL /
/// history survives window close + reopen + app restart.
@MainActor
final class BrowserWindowManager: ObservableObject {
	static let shared = BrowserWindowManager()

	private var windows: [UUID: NSWindow] = [:]
	private var observers: [UUID: [NSObjectProtocol]] = [:]
	private var layoutStates: [UUID: ProjectLayoutState] = [:]
	/// project ごとの window delegate。`windowWillResize` で aspect を維持。
	/// retain しておかないと NSWindow の delegate は weak 参照なので即解放される。
	private var resizers: [UUID: BrowserWindowResizer] = [:]
	/// Published set of projects whose browser is currently in thumbnail mode
	/// so BrowserView can reshape itself (hide URL bar, enlarge click target).
	@Published private(set) var thumbnails: Set<UUID> = []
	private var appActiveObservers: [NSObjectProtocol] = []

	private init() {
		// Bridge "Belve is the foreground app" → window level.
		// `.floating` keeps the browser above the main app window; `.normal`
		// when Belve is in the background lets other apps' windows come on
		// top. The user wants "above Belve, but not above Slack/Chrome".
		appActiveObservers.append(
			NotificationCenter.default.addObserver(
				forName: NSApplication.didBecomeActiveNotification,
				object: nil, queue: .main
			) { [weak self] _ in
				Task { @MainActor in self?.applyLevels(.floating) }
			}
		)
		appActiveObservers.append(
			NotificationCenter.default.addObserver(
				forName: NSApplication.didResignActiveNotification,
				object: nil, queue: .main
			) { [weak self] _ in
				Task { @MainActor in self?.applyLevels(.normal) }
			}
		)
		// モニター構成変更 (= 接続/切断、解像度変更) → 既存ウィンドウを clamp。
		// これがないとモニター取り外し時にブラウザが画面外に取り残されて
		// 操作不能になる。
		appActiveObservers.append(
			NotificationCenter.default.addObserver(
				forName: NSApplication.didChangeScreenParametersNotification,
				object: nil, queue: .main
			) { [weak self] _ in
				Task { @MainActor in self?.reclampAllToVisibleScreens() }
			}
		)
	}

	private func applyLevels(_ level: NSWindow.Level) {
		for window in windows.values {
			window.level = level
		}
	}

	/// Toggle cycles through three states:
	///   (hidden) → full size
	///   full size → thumbnail (via `hide`)
	///   thumbnail → full size (via `restore`)
	/// Window + web state are preserved across all transitions so reappearing
	/// is instant.
	func toggle(project: Project, layoutState: ProjectLayoutState) {
		if let existing = windows[project.id] {
			if !existing.isVisible {
				existing.makeKeyAndOrderFront(nil)
				NSApp.activate(ignoringOtherApps: true)
			} else if thumbnails.contains(project.id) {
				restore(projectId: project.id)
			} else {
				hide(projectId: project.id)
			}
			return
		}
		open(project: project, layoutState: layoutState)
	}

	func open(project: Project, layoutState: ProjectLayoutState) {
		if let existing = windows[project.id] {
			existing.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		// Borderless floating panel — chrome is all drawn inside the SwiftUI
		// content (traffic-light-style close + hide buttons in the URL bar).
		// `.floating` keeps it above the main app + other apps for
		// side-by-side debugging. Use the subclass below so the panel can
		// become key (the borderless NSPanel default returns false, which
		// stops Cmd+R from being routed to it).
		let window = FloatingBrowserPanel(
			contentRect: NSRect(x: 120, y: 120, width: 980, height: 720),
			styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		// Initial level reflects current app activity — `applyLevels` keeps
		// it in sync afterwards.
		window.level = NSApp.isActive ? .floating : .normal
		window.hidesOnDeactivate = false
		window.isMovableByWindowBackground = false
		// NSPanel defaults to `becomesKeyOnlyIfNeeded = true`, which prevents
		// it from becoming the key window on a regular click — so
		// `NSApp.keyWindow` stays on the main app and Cmd+R routes to project
		// reload instead of browser reload. Force key-on-click here.
		window.becomesKeyOnlyIfNeeded = false
		let frameName = "BelveBrowser-\(project.id.uuidString.prefix(8))"
		// Identifier used by `BelveApp` (Cmd+R routing) — explicitly NOT using
		// `setFrameAutosaveName` because that would conflate the thumbnail's
		// 160×100 with the user's full-size frame on the next launch.
		// We store the full frame ourselves in `layoutState.browserFrame`.
		window.identifier = NSUserInterfaceItemIdentifier(rawValue: frameName)
		if let saved = layoutState.browserFrame {
			// 別モニター環境で復元すると saved.rect が現在のスクリーン範囲外を
			// 指してウィンドウが画面外 (= 操作不能) になる事故が起きるので、
			// 必ず現存スクリーンに収まる範囲に clamp する。
			window.setFrame(Self.clampedToVisibleScreens(saved.rect), display: false)
		}
		window.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
		window.hasShadow = true

		let host = NSHostingController(
			rootView: BrowserHostView(
				manager: self,
				projectId: project.id,
				layoutState: layoutState,
				portForwards: project.portForwards
			)
		)
		window.contentView = host.view
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		windows[project.id] = window
		layoutStates[project.id] = layoutState
		layoutState.browserOpen = true

		// 仮想 viewport が既に設定されてる project (前回起動から復元) なら
		// resizer に viewport をセット → windowWillResize で aspect 維持。
		let resizer = BrowserWindowResizer()
		resizer.virtualViewport = layoutState.browserViewport?.size
		window.delegate = resizer
		resizers[project.id] = resizer

		var tokens: [NSObjectProtocol] = []
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification,
			object: window,
			queue: .main
		) { [weak self] _ in
			Task { @MainActor in
				self?.cleanup(projectId: project.id, persistOpen: false)
			}
		})
		// Persist the user's preferred frame on every move/resize, but ONLY
		// while not in thumbnail mode (otherwise the 160×100 thumbnail
		// dimensions would overwrite the saved full-size frame).
		let frameObserver: (Notification) -> Void = { [weak self] _ in
			guard let self else { return }
			Task { @MainActor in
				guard !self.thumbnails.contains(project.id) else { return }
				self.layoutStates[project.id]?.browserFrame = StoredFrame(window.frame)
			}
		}
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification, object: window, queue: .main, using: frameObserver
		))
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.didResizeNotification, object: window, queue: .main, using: frameObserver
		))
		observers[project.id] = tokens

		// Restore thumbnail state if the user had it shrunk last time.
		if layoutState.browserThumbnail {
			Task { @MainActor in self.hide(projectId: project.id) }
		}
	}

	/// 避難: shrink to a thumbnail in the bottom-right corner instead of
	/// fully hiding. The web content keeps rendering so the user can glance
	/// at it; clicking the thumbnail restores the persisted full-size frame.
	/// The full frame is preserved in `layoutState.browserFrame`, which the
	/// frame observer in `open(...)` stops updating while in thumbnail mode.
	func hide(projectId: UUID) {
		guard let window = windows[projectId] else { return }
		if thumbnails.contains(projectId) { return }
		// Capture the full-size frame in case the observer hasn't fired yet
		// (very fresh window).
		layoutStates[projectId]?.browserFrame = StoredFrame(window.frame)
		let screen = window.screen ?? NSScreen.main!
		let size = NSSize(width: 160, height: 100)
		let origin = NSPoint(
			x: screen.visibleFrame.maxX - size.width - 12,
			y: screen.visibleFrame.minY + 12
		)
		thumbnails.insert(projectId)
		layoutStates[projectId]?.browserThumbnail = true
		window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
	}

	func restore(projectId: UUID) {
		guard let window = windows[projectId] else { return }
		thumbnails.remove(projectId)
		layoutStates[projectId]?.browserThumbnail = false
		if let saved = layoutStates[projectId]?.browserFrame {
			window.setFrame(saved.rect, display: true, animate: true)
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func isThumbnail(projectId: UUID) -> Bool {
		thumbnails.contains(projectId)
	}

	func isVisible(projectId: UUID) -> Bool {
		windows[projectId]?.isVisible ?? false
	}

	func close(projectId: UUID) {
		windows[projectId]?.close()
	}

	/// Hide every browser window that doesn't belong to `keepProjectId`.
	/// Called from the project-switch path so only the active project's
	/// browser stays on screen — without losing the others' state (their
	/// `browserOpen` / `browserFrame` persist).
	func hideAllExcept(keepProjectId: UUID?) {
		for (id, window) in windows where id != keepProjectId {
			window.orderOut(nil)
		}
	}

	func bringForward(projectId: UUID) {
		guard let window = windows[projectId] else { return }
		if !window.isVisible { window.makeKeyAndOrderFront(nil) }
		else { window.orderFront(nil) }
	}

	/// 仮想 viewport が変更された時に呼ぶ。
	/// - 指定あり: window の content aspect を viewport 比 + URL バー高さで固定し、
	///   現在の幅を保ったまま高さをアスペクト比に合わせて調整する (= レターボックス
	///   が出ない)。ユーザーがウィンドウを resize しても比率は維持される。
	/// - 指定なし: aspect 制約を解除して自由 resize に戻す。
	func applyViewport(projectId: UUID, viewport: CGSize?) {
		guard let window = windows[projectId], let resizer = resizers[projectId] else { return }
		resizer.virtualViewport = viewport
		guard let v = viewport, v.width > 0, v.height > 0 else { return }
		// 即時整形: 現在の幅を維持しつつ、resizer と同じ計算で高さを合わせる。
		// (以降のドラッグ resize は windowWillResize が拾う)
		let urlBarHeight = resizer.urlBarHeight
		let currentFrame = window.frame
		let screen = window.screen ?? NSScreen.main!
		let visible = screen.visibleFrame
		var w = currentFrame.width
		var h = w * v.height / v.width + urlBarHeight
		if h > visible.height * 0.9 {
			h = visible.height * 0.9
			w = (h - urlBarHeight) * v.width / v.height
		}
		let dx = currentFrame.width - w
		let dy = currentFrame.height - h
		let newFrame = NSRect(
			x: currentFrame.minX + dx / 2,
			y: currentFrame.minY + dy, // 上端固定 (AppKit y は上向き)
			width: w,
			height: h
		)
		window.setFrame(newFrame, display: true, animate: true)
	}

	/// SwiftUI 側 (BrowserView) で URL バー高さが計測されたら呼ぶ。
	/// resizer に反映 → 次回以降の resize で正確な aspect になる。
	func updateURLBarHeight(projectId: UUID, height: CGFloat) {
		guard let resizer = resizers[projectId], height > 0 else { return }
		if abs(resizer.urlBarHeight - height) < 0.5 { return }
		resizer.urlBarHeight = height
	}

	/// 現存するスクリーンと一切重ならない frame は main screen 中央寄りに、
	/// 重なるが部分的にはみ出してる場合は重なってる screen の visibleFrame に
	/// 収まるよう移動 + サイズ縮小する。restoreFrame の clamp と
	/// `didChangeScreenParameters` の reclamp 両方で使う。
	static func clampedToVisibleScreens(_ frame: CGRect) -> CGRect {
		let screens = NSScreen.screens
		guard !screens.isEmpty else { return frame }
		// どの screen とも交差しない場合は main screen の中央寄りに置き直す。
		let intersecting = screens.first(where: { $0.visibleFrame.intersects(frame) })
		let target = intersecting?.visibleFrame ?? (NSScreen.main ?? screens[0]).visibleFrame
		var bounded = frame
		// サイズが target より大きい場合は target に収める
		bounded.size.width = min(bounded.width, target.width)
		bounded.size.height = min(bounded.height, target.height)
		// 完全画面外なら中央配置
		if intersecting == nil {
			bounded.origin.x = target.midX - bounded.width / 2
			bounded.origin.y = target.midY - bounded.height / 2
		} else {
			// 部分はみ出しは visibleFrame 内に押し込む
			bounded.origin.x = max(target.minX, min(bounded.minX, target.maxX - bounded.width))
			bounded.origin.y = max(target.minY, min(bounded.minY, target.maxY - bounded.height))
		}
		return bounded
	}

	/// モニター構成が変わった時に既存ウィンドウを clamp し直す。
	/// `didChangeScreenParametersNotification` から呼ばれる。
	private func reclampAllToVisibleScreens() {
		for (_, window) in windows {
			let current = window.frame
			let clamped = Self.clampedToVisibleScreens(current)
			if clamped != current {
				window.setFrame(clamped, display: true, animate: true)
			}
		}
	}

	/// Cmd palette 等から呼ぶ「強制的にブラウザを画面内に戻す」コマンド。
	/// モニター構成変更を Belve 側が察知できないケース (= スリープ復帰のラグ等)
	/// の手動 fallback。
	@MainActor
	func recenterAllBrowserWindows() {
		for (_, window) in windows {
			let main = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
			var f = window.frame
			f.size.width = min(f.width, main.width)
			f.size.height = min(f.height, main.height)
			f.origin.x = main.midX - f.width / 2
			f.origin.y = main.midY - f.height / 2
			window.setFrame(f, display: true, animate: true)
			window.makeKeyAndOrderFront(nil)
		}
	}

	private func cleanup(projectId: UUID, persistOpen: Bool) {
		windows.removeValue(forKey: projectId)
		if let tokens = observers.removeValue(forKey: projectId) {
			tokens.forEach(NotificationCenter.default.removeObserver)
		}
		thumbnails.remove(projectId)
		resizers.removeValue(forKey: projectId)
		if !persistOpen, let ls = layoutStates[projectId] {
			ls.browserOpen = false
			ls.browserThumbnail = false
		}
		layoutStates.removeValue(forKey: projectId)
	}
}
