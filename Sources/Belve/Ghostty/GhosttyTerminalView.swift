import GhosttyKit
import SwiftUI
import AppKit

/// SwiftUI wrapper for GhosttyTerminalNSView. Drop-in replacement for TerminalPaneView.
struct GhosttyTerminalView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	@EnvironmentObject var notificationStore: NotificationStore
	@EnvironmentObject var commandAreaState: CommandAreaState

	func makeNSView(context: Context) -> GhosttyTerminalNSView {
		// Ensure the Ghostty runtime is initialized (lazy singleton)
		_ = GhosttyRuntime.shared

		let view = GhosttyTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

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

		// Set command for SSH / DevContainer connections
		if project.isDevContainer, let sshHost = project.sshHost, let workspacePath = project.devContainerPath {
			// DevContainer: ssh into host, then devcontainer exec
			BelveRemoteInstaller.deploy(to: sshHost)
			let args = DevContainerService.exec(sshHost: sshHost, workspacePath: workspacePath)
			view.command = args.joined(separator: " ")
			NSLog("[Belve] DevContainer mode: \(sshHost):\(workspacePath)")
		} else if let sshHost = project.sshHost {
			// SSH: connect to remote host
			BelveRemoteInstaller.deploy(to: sshHost)
			view.command = "/usr/bin/ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -t \(sshHost)"
			NSLog("[Belve] SSH mode: \(sshHost)")
		}

		// Register pane → project mapping for agent notifications
		if let paneId {
			notificationStore.registerPane(paneId: paneId, projectId: project.id)
		}

		// Track active pane on focus
		if let paneId, let paneUUID = UUID(uuidString: paneId) {
			view.onBecomeFirstResponder = { [weak commandAreaState] in
				commandAreaState?.activePaneId = paneUUID
			}
		}

		// Handle surface close (shell exit) — remove pane from tree
		let closePaneId = paneId
		view.onSurfaceClosed = { [weak commandAreaState] in
			NSLog("[Belve] Terminal surface closed for project: \(project.name)")
			if let closePaneId, let paneUUID = UUID(uuidString: closePaneId) {
				DispatchQueue.main.async {
					commandAreaState?.removePane(paneUUID)
				}
			}
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
