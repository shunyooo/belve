import AppKit
import SwiftUI

/// Shows an arbitrary SwiftUI view as a floating borderless panel anchored to a
/// screen point. Use this when SwiftUI's overlay positioning is awkward (e.g.
/// mouse-anchored context menus in hidden-titlebar windows) but the look of a
/// native NSMenu is too bland.
///
/// Lifecycle: the popup auto-dismisses on any click outside itself, on Escape,
/// or when the host window resigns key. The caller can also close it via
/// `close()` (commonly from inside the content view after an action fires).
@MainActor
final class FloatingMenuPopup {
	static let shared = FloatingMenuPopup()

	private var panel: NSPanel?
	private var globalMonitor: Any?
	private var localMonitor: Any?
	private var keyMonitor: Any?

	/// Show the popup. `screenPoint` is the top-left of the popup in screen
	/// coords (AppKit — y=0 at bottom). The method flips internally so callers
	/// can pass the raw mouse location; the popup top-left lands at the cursor.
	func show<Content: View>(
		at screenPoint: NSPoint,
		size: NSSize,
		@ViewBuilder content: () -> Content
	) {
		close()
		let adjustedOrigin = NSPoint(x: screenPoint.x, y: screenPoint.y - size.height)
		let panel = NSPanel(
			contentRect: NSRect(origin: adjustedOrigin, size: size),
			styleMask: [.nonactivatingPanel, .borderless],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = false // SwiftUI draws its own drop shadow
		panel.level = .popUpMenu
		panel.isMovableByWindowBackground = false
		panel.hidesOnDeactivate = true
		panel.contentView = NSHostingView(rootView: content())
		panel.orderFront(nil)
		self.panel = panel

		// Guard monitors against a race: each monitor only closes the panel it
		// was created for. Without this guard, a monitor that fires on the
		// boundary between two `show()` calls can close the newly-opened panel.
		globalMonitor = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self, weak panel] _ in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return }
				self.close()
			}
		}
		localMonitor = NSEvent.addLocalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self, weak panel] event in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return event }
				if event.window !== panel { self.close() }
				return event
			}
		}
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
			MainActor.assumeIsolated {
				guard let self, self.panel === panel else { return event }
				if event.keyCode == 53 { // Escape
					self.close()
					return nil
				}
				return event
			}
		}
	}

	func close() {
		panel?.orderOut(nil)
		panel = nil
		if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
		if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
		if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
	}
}
