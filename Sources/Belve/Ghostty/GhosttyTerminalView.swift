import GhosttyKit
import SwiftUI
import AppKit

/// SwiftUI wrapper for GhosttyTerminalNSView. Drop-in replacement for TerminalPaneView.
struct GhosttyTerminalView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	@EnvironmentObject var notificationStore: NotificationStore

	func makeNSView(context: Context) -> GhosttyTerminalNSView {
		// Ensure the Ghostty runtime is initialized (lazy singleton)
		_ = GhosttyRuntime.shared

		let view = GhosttyTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
		// Ghostty will use the user's home directory if no working directory is set.
		// For remote projects we leave it nil and let the shell handle it.

		// Build environment
		var env: [String: String] = [
			"BELVE_SESSION": "1",
		]
		if let paneId {
			env["BELVE_PANE_ID"] = paneId
		}
		env["BELVE_PROJECT_ID"] = project.id.uuidString

		// Add Belve's bin directory to PATH
		if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
			let resourceBin = execDir
				.deletingLastPathComponent()
				.appendingPathComponent("Resources/bin")
			let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
			env["PATH"] = "\(resourceBin.path):\(currentPath)"
		}

		view.environmentVariables = env

		// Handle surface close (shell exit)
		view.onSurfaceClosed = {
			NSLog("[Belve] Terminal surface closed for project: \(project.name)")
		}

		// Request first responder after layout settles
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
			view.window?.makeFirstResponder(view)
		}

		return view
	}

	func updateNSView(_ nsView: GhosttyTerminalNSView, context: Context) {
		// No dynamic updates needed for now
	}
}
