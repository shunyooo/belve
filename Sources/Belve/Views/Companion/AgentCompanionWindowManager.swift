import AppKit
import SwiftUI

/// Agent Dock の floating NSPanel を 1 つだけ管理する。
/// 複数 companion が dock 内に並ぶ (= panel 1 つ、SwiftUI 側が複数 avatar を描画)。
@MainActor
final class AgentCompanionWindowManager {
	static let shared = AgentCompanionWindowManager()

	private var dockPanel: AgentDockPanel?
	private var userHidden = false

	private init() {}

	func toggleVisibility() {
		if let p = dockPanel, p.isVisible {
			userHidden = true
			p.orderOut(nil)
		} else if let p = dockPanel {
			userHidden = false
			p.orderFrontRegardless()
		} else {
			userHidden = false
		}
	}

	private static let positionKey = "Belve.companionDock.position"

	/// Companion が 1 つ以上あれば dock を表示、0 なら非表示。
	/// AgentCompanionStore.reconcile から呼ばれる。
	func updateDock(hasCompanions: Bool) {
		if hasCompanions {
			if dockPanel == nil && !userHidden {
				let panel = AgentDockPanel()
				dockPanel = panel
				restoreOrPositionDock(panel)
				panel.orderFrontRegardless()
				observeDockMoves(panel)
			}
		} else {
			saveDockPosition()
			dismissDock()
			userHidden = false
		}
	}

	/// Companion 個別の dismiss 用 (= 互換 API)。Store 側で companion を消した後に呼ぶ。
	func dismiss(paneId: String) {
		// Dock は single panel なので個別 dismiss は不要。
		// Store 側で companion が消えれば dock view が自動で更新される。
		// companions が 0 になれば updateDock(hasCompanions: false) で dock ごと消える。
	}

	func dismissAll() {
		dismissDock()
	}

	// 旧 API 互換: upsert は何もしない (= dock は store observe で自動更新)
	func upsert(companion: AgentCompanion) {}

	// 旧 API 互換: propagateMove は dock では不要
	func propagateMove(from sourcePaneId: String, delta: NSPoint) {}

	private var moveObserver: Any?

	private func dismissDock() {
		saveDockPosition()
		if let obs = moveObserver {
			NotificationCenter.default.removeObserver(obs)
			moveObserver = nil
		}
		dockPanel?.close()
		dockPanel = nil
	}

	private func restoreOrPositionDock(_ panel: AgentDockPanel) {
		if let dict = UserDefaults.standard.dictionary(forKey: Self.positionKey),
		   let x = dict["x"] as? Double,
		   let y = dict["y"] as? Double {
			panel.setFrameOrigin(NSPoint(x: x, y: y))
		} else {
			guard let screen = NSScreen.main else { return }
			let visible = screen.visibleFrame
			let panelSize = panel.frame.size
			let x = visible.midX - panelSize.width / 2
			let y = visible.minY + 16
			panel.setFrameOrigin(NSPoint(x: x, y: y))
		}
	}

	private func observeDockMoves(_ panel: AgentDockPanel) {
		moveObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification, object: panel, queue: .main
		) { [weak self] _ in
			self?.saveDockPosition()
		}
	}

	private func saveDockPosition() {
		guard let panel = dockPanel else { return }
		let origin = panel.frame.origin
		UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: Self.positionKey)
	}
}

/// Dock 用の floating NSPanel。画面下部中央に配置。
final class AgentDockPanel: NSPanel {
	private let host: NSHostingController<AgentDockView>

	init() {
		let notifStore = (NSApp.delegate as? AppDelegate)?.notificationStore ?? NotificationStore()
		self.host = NSHostingController(
			rootView: AgentDockView(notificationStore: notifStore)
		)
		let screenWidth = NSScreen.main?.frame.width ?? 1920
		let initialFrame = NSRect(x: 0, y: 0, width: screenWidth, height: 300)
		super.init(
			contentRect: initialFrame,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: false
		)
		self.isFloatingPanel = true
		self.level = .floating
		self.becomesKeyOnlyIfNeeded = true
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = false
		self.hidesOnDeactivate = false
		self.isMovableByWindowBackground = true
		self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
		let hostView = host.view
		hostView.wantsLayer = true
		hostView.frame = self.contentView!.bounds
		hostView.autoresizingMask = [.width, .height]
		self.contentView!.addSubview(hostView)
		// sizingOptions は AnyView + onChange の組み合わせで rendering が壊れるので使わない。
		// Panel は十分大きめに確保し、SwiftUI content は内部で適切にサイズ調整する。
	}
}
