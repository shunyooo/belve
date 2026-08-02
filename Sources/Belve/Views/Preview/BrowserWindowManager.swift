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
	let windowId: UUID
	@ObservedObject var windowState: BrowserWindowState
	let project: Project
	let layoutState: ProjectLayoutState

	var body: some View {
		BrowserView(
			windowState: windowState,
			portForwards: project.portForwards,
			onHide: { manager.hide(windowId: windowId) },
			onClose: { manager.close(windowId: windowId) },
			onRestore: { manager.restore(windowId: windowId) },
			onNewWindow: { manager.newWindow(project: project, layoutState: layoutState) },
			isThumbnail: manager.thumbnails.contains(windowId),
			onViewportChanged: { viewport in
				manager.applyViewport(windowId: windowId, viewport: viewport)
			},
			onURLBarHeightChanged: { h in
				manager.updateURLBarHeight(windowId: windowId, height: h)
			}
		)
	}
}

/// Spawns standalone floating browser windows. A project can have MULTIPLE
/// windows, each with its own `BrowserWindowState` (url / frame / viewport /
/// thumbnail / open), persisted on `ProjectLayoutState.browserWindows` so they
/// survive close→reopen and app restart. Everything is keyed by windowId
/// (`BrowserWindowState.id`); `windowProjects` keeps the windowId→project
/// association for project-switch hide/restore, app-level, and Cmd+R routing.
@MainActor
final class BrowserWindowManager: ObservableObject {
	static let shared = BrowserWindowManager()

	private var windows: [UUID: NSWindow] = [:]
	private var observers: [UUID: [NSObjectProtocol]] = [:]
	/// windowId → 永続状態 (frame/thumbnail の書き戻し先)。
	private var states: [UUID: BrowserWindowState] = [:]
	/// windowId → 所属 project とその layoutState。
	private var windowProjects: [UUID: (projectId: UUID, project: Project, layoutState: ProjectLayoutState)] = [:]
	/// windowId → window delegate。`windowWillResize` で aspect を維持。
	/// retain しておかないと NSWindow の delegate は weak 参照なので即解放される。
	private var resizers: [UUID: BrowserWindowResizer] = [:]
	/// Published set of windowIds currently in thumbnail mode so BrowserView can
	/// reshape itself (hide URL bar, enlarge click target).
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

	/// Cmd+Shift+B: 窓が 0 個なら 1 個作る。1 個以上あればその project の全窓を
	/// まとめて表示/非表示トグルする。
	func toggle(project: Project, layoutState: ProjectLayoutState) {
		let ids = windowIds(for: project.id)
		if ids.isEmpty {
			newWindow(project: project, layoutState: layoutState)
			return
		}
		let anyVisible = ids.contains { windows[$0]?.isVisible == true }
		if anyVisible {
			for id in ids { windows[id]?.orderOut(nil) }
		} else {
			for id in ids { windows[id]?.makeKeyAndOrderFront(nil) }
			NSApp.activate(ignoringOtherApps: true)
		}
	}

	/// 新しい窓を 1 個生成する (既存とは独立)。"+" ボタン / パレットから呼ぶ。
	func newWindow(project: Project, layoutState: ProjectLayoutState) {
		let state = BrowserWindowState(open: true)
		layoutState.browserWindows.append(state)
		open(project: project, layoutState: layoutState, windowState: state)
	}

	/// project 復帰時に、前回 open だった窓を再オープンする。
	func restoreOpenWindows(project: Project, layoutState: ProjectLayoutState) {
		for state in layoutState.browserWindows where state.open {
			open(project: project, layoutState: layoutState, windowState: state)
		}
	}

	func open(project: Project, layoutState: ProjectLayoutState, windowState: BrowserWindowState) {
		// 既に開いている窓は前面へ (二重生成しない)。
		if let existing = windows[windowState.id] {
			existing.makeKeyAndOrderFront(nil)
			NSApp.activate(ignoringOtherApps: true)
			return
		}

		// Borderless floating panel — chrome is all drawn inside the SwiftUI
		// content (traffic-light-style close + hide buttons in the URL bar).
		// `.floating` keeps it above the main app + other apps for
		// side-by-side debugging. Use the subclass so the panel can become key
		// (the borderless NSPanel default returns false, which stops Cmd+R
		// from being routed to it).
		let window = FloatingBrowserPanel(
			contentRect: NSRect(x: 120, y: 120, width: 980, height: 720),
			styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.level = NSApp.isActive ? .floating : .normal
		window.hidesOnDeactivate = false
		window.isMovableByWindowBackground = false
		// NSPanel defaults to `becomesKeyOnlyIfNeeded = true`, which prevents it
		// from becoming key on a regular click — so `NSApp.keyWindow` stays on
		// the main app and Cmd+R routes to project reload. Force key-on-click.
		window.becomesKeyOnlyIfNeeded = false
		// Identifier used by `BelveApp` (Cmd+R routing) — prefix "BelveBrowser-"
		// で「これはブラウザ窓」と判定する。どの窓かは key window の
		// firstResponder (isKeyWindow filter) で解決するので prefix で十分。
		let frameName = "BelveBrowser-\(windowState.id.uuidString.prefix(8))"
		window.identifier = NSUserInterfaceItemIdentifier(rawValue: frameName)
		if let saved = windowState.frame {
			// 別モニター環境で復元すると saved.rect が現在のスクリーン範囲外を
			// 指してウィンドウが画面外 (= 操作不能) になる事故が起きるので、
			// 必ず現存スクリーンに収まる範囲に clamp する。
			window.setFrame(Self.clampedToVisibleScreens(saved.rect), display: false)
		} else {
			// 新規窓は既存 sibling の枚数ぶんカスケードして重ならないようにする。
			let n = windowIds(for: project.id).count
			let offset = CGFloat(n) * 28
			var f = window.frame
			f.origin = NSPoint(x: f.origin.x + offset, y: f.origin.y - offset)
			window.setFrame(Self.clampedToVisibleScreens(f), display: false)
		}
		window.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
		window.hasShadow = true

		let host = NSHostingController(
			rootView: BrowserHostView(
				manager: self,
				windowId: windowState.id,
				windowState: windowState,
				project: project,
				layoutState: layoutState
			)
		)
		window.contentView = host.view
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
		windows[windowState.id] = window
		states[windowState.id] = windowState
		windowProjects[windowState.id] = (project.id, project, layoutState)
		windowState.open = true

		// 仮想 viewport が既に設定されてる (前回起動から復元) なら resizer に
		// viewport をセット → windowWillResize で aspect 維持。
		let resizer = BrowserWindowResizer()
		resizer.virtualViewport = windowState.viewport?.size
		window.delegate = resizer
		resizers[windowState.id] = resizer

		let windowId = windowState.id
		var tokens: [NSObjectProtocol] = []
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.willCloseNotification, object: window, queue: .main
		) { [weak self] _ in
			Task { @MainActor in self?.handleWindowClosed(windowId: windowId) }
		})
		// Persist the user's preferred frame on every move/resize, but ONLY
		// while not in thumbnail mode (otherwise the 160×100 thumbnail
		// dimensions would overwrite the saved full-size frame).
		let frameObserver: (Notification) -> Void = { [weak self] _ in
			guard let self else { return }
			Task { @MainActor in
				guard !self.thumbnails.contains(windowId) else { return }
				self.states[windowId]?.frame = StoredFrame(window.frame)
			}
		}
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification, object: window, queue: .main, using: frameObserver
		))
		tokens.append(NotificationCenter.default.addObserver(
			forName: NSWindow.didResizeNotification, object: window, queue: .main, using: frameObserver
		))
		observers[windowId] = tokens

		// Restore thumbnail state if the user had it shrunk last time.
		if windowState.thumbnail {
			Task { @MainActor in self.hide(windowId: windowId) }
		}
	}

	/// 避難: shrink to a thumbnail in the bottom-right corner instead of fully
	/// hiding. The web content keeps rendering so the user can glance at it;
	/// clicking the thumbnail restores the persisted full-size frame.
	func hide(windowId: UUID) {
		guard let window = windows[windowId] else { return }
		if thumbnails.contains(windowId) { return }
		// Capture the full-size frame in case the observer hasn't fired yet.
		states[windowId]?.frame = StoredFrame(window.frame)
		let screen = window.screen ?? NSScreen.main!
		let size = NSSize(width: 160, height: 100)
		let origin = NSPoint(
			x: screen.visibleFrame.maxX - size.width - 12,
			y: screen.visibleFrame.minY + 12
		)
		thumbnails.insert(windowId)
		states[windowId]?.thumbnail = true
		window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
	}

	func restore(windowId: UUID) {
		guard let window = windows[windowId] else { return }
		thumbnails.remove(windowId)
		states[windowId]?.thumbnail = false
		if let saved = states[windowId]?.frame {
			window.setFrame(saved.rect, display: true, animate: true)
		}
		window.makeKeyAndOrderFront(nil)
		NSApp.activate(ignoringOtherApps: true)
	}

	func isThumbnail(windowId: UUID) -> Bool {
		thumbnails.contains(windowId)
	}

	func close(windowId: UUID) {
		windows[windowId]?.close()
	}

	/// Hide every browser window that doesn't belong to `keepProjectId`.
	/// Called from the project-switch path so only the active project's windows
	/// stay on screen — without losing the others' state (their windows keep
	/// `open:true` and are restored when their project is re-selected).
	func hideAllExcept(keepProjectId: UUID?) {
		for (id, assoc) in windowProjects where assoc.projectId != keepProjectId {
			windows[id]?.orderOut(nil)
		}
	}

	/// 仮想 viewport が変更された時に呼ぶ。指定ありで aspect を固定、なしで自由 resize。
	func applyViewport(windowId: UUID, viewport: CGSize?) {
		guard let window = windows[windowId], let resizer = resizers[windowId] else { return }
		resizer.virtualViewport = viewport
		guard let v = viewport, v.width > 0, v.height > 0 else { return }
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
	func updateURLBarHeight(windowId: UUID, height: CGFloat) {
		guard let resizer = resizers[windowId], height > 0 else { return }
		if abs(resizer.urlBarHeight - height) < 0.5 { return }
		resizer.urlBarHeight = height
	}

	/// 現存スクリーンと一切重ならない frame は main 中央寄りに、部分はみ出しは
	/// 重なる screen の visibleFrame に収める。restore の clamp と screen 変更の
	/// reclamp 両方で使う。
	static func clampedToVisibleScreens(_ frame: CGRect) -> CGRect {
		let screens = NSScreen.screens
		guard !screens.isEmpty else { return frame }
		let intersecting = screens.first(where: { $0.visibleFrame.intersects(frame) })
		let target = intersecting?.visibleFrame ?? (NSScreen.main ?? screens[0]).visibleFrame
		var bounded = frame
		bounded.size.width = min(bounded.width, target.width)
		bounded.size.height = min(bounded.height, target.height)
		if intersecting == nil {
			bounded.origin.x = target.midX - bounded.width / 2
			bounded.origin.y = target.midY - bounded.height / 2
		} else {
			bounded.origin.x = max(target.minX, min(bounded.minX, target.maxX - bounded.width))
			bounded.origin.y = max(target.minY, min(bounded.minY, target.maxY - bounded.height))
		}
		return bounded
	}

	/// モニター構成が変わった時に既存ウィンドウを clamp し直す。
	private func reclampAllToVisibleScreens() {
		for (_, window) in windows {
			let current = window.frame
			let clamped = Self.clampedToVisibleScreens(current)
			if clamped != current {
				window.setFrame(clamped, display: true, animate: true)
			}
		}
	}

	/// Cmd palette 等から呼ぶ「強制的に全ブラウザを画面内に戻す」コマンド。
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

	/// 窓が実際に閉じた (= ユーザーが赤ボタンで close / 明示 close)。台帳を全消しし、
	/// 永続状態からも entry を除去する (閉じた窓は復元しない = forget)。project 切替の
	/// orderOut は willClose を発火しないので、そちらは entry を残す (open:true のまま)。
	private func handleWindowClosed(windowId: UUID) {
		windows.removeValue(forKey: windowId)
		if let tokens = observers.removeValue(forKey: windowId) {
			tokens.forEach(NotificationCenter.default.removeObserver)
		}
		thumbnails.remove(windowId)
		resizers.removeValue(forKey: windowId)
		if let assoc = windowProjects[windowId] {
			assoc.layoutState.browserWindows.removeAll { $0.id == windowId }
		}
		windowProjects.removeValue(forKey: windowId)
		states.removeValue(forKey: windowId)
	}

	private func windowIds(for projectId: UUID) -> [UUID] {
		windowProjects.filter { $0.value.projectId == projectId }.map { $0.key }
	}
}
