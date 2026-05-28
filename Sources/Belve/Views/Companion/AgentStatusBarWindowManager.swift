import AppKit
import SwiftUI

@MainActor
final class AgentStatusBarWindowManager {
	static let shared = AgentStatusBarWindowManager()

	private var panel: AgentStatusBarPanel?
	private var moveObserver: Any?
	private static let positionKey = "Belve.statusBar.position"

	private var userHidden = false

	private init() {}

	func toggleVisibility() {
		if let p = panel, p.isVisible {
			userHidden = true
			p.orderOut(nil)
		} else if let p = panel {
			userHidden = false
			p.orderFrontRegardless()
		} else {
			userHidden = false
		}
	}

	func updateStatusBar(hasCompanions: Bool) {
		if hasCompanions {
			if panel == nil && !userHidden {
				let p = AgentStatusBarPanel()
				panel = p
				restoreOrPosition(p)
				p.orderFrontRegardless()
				observeMoves(p)
			}
		} else {
			dismiss()
			userHidden = false
		}
	}

	func dismiss() {
		savePosition()
		if let obs = moveObserver {
			NotificationCenter.default.removeObserver(obs)
			moveObserver = nil
		}
		panel?.close()
		panel = nil
	}

	private func restoreOrPosition(_ panel: AgentStatusBarPanel) {
		if let dict = UserDefaults.standard.dictionary(forKey: Self.positionKey),
		   let x = dict["x"] as? Double,
		   let y = dict["y"] as? Double {
			panel.setFrameOrigin(NSPoint(x: x, y: y))
		} else {
			guard let screen = NSScreen.main else { return }
			let visible = screen.visibleFrame
			let panelSize = panel.frame.size
			let x = visible.midX - panelSize.width / 2
			let y = visible.maxY - panelSize.height - 8
			panel.setFrameOrigin(NSPoint(x: x, y: y))
		}
	}

	private func observeMoves(_ panel: AgentStatusBarPanel) {
		moveObserver = NotificationCenter.default.addObserver(
			forName: NSWindow.didMoveNotification, object: panel, queue: .main
		) { [weak self] _ in
			self?.savePosition()
		}
	}

	private func savePosition() {
		guard let panel else { return }
		let origin = panel.frame.origin
		UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: Self.positionKey)
	}
}

final class AgentStatusBarPanel: NSPanel {
	private let host: NSHostingController<AgentStatusBarView>

	init() {
		let notifStore = (NSApp.delegate as? AppDelegate)?.notificationStore ?? NotificationStore()
		self.host = NSHostingController(
			rootView: AgentStatusBarView(notificationStore: notifStore)
		)
		let screenWidth = NSScreen.main?.frame.width ?? 1920
		let initialFrame = NSRect(x: 0, y: 0, width: screenWidth, height: 200)
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
	}
}
