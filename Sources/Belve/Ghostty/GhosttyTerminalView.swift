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

		// Set connection mode via environment variables (handled by launcher script)
		if project.isDevContainer, let sshHost = project.sshHost, let workspacePath = project.devContainerPath {
			BelveRemoteInstaller.deploy(to: sshHost)
			env["BELVE_SSH_HOST"] = sshHost
			env["BELVE_REMOTE_PATH"] = workspacePath
			env["BELVE_DEVCONTAINER"] = "1"
			NSLog("[Belve] DevContainer mode: \(sshHost):\(workspacePath)")
		} else if let sshHost = project.sshHost {
			BelveRemoteInstaller.deploy(to: sshHost)
			env["BELVE_SSH_HOST"] = sshHost
			if let remotePath = project.remotePath {
				env["BELVE_REMOTE_PATH"] = remotePath
			}
			NSLog("[Belve] SSH mode: \(sshHost), remotePath: \(project.remotePath ?? "none")")
		} else if let remotePath = project.remotePath {
			view.workingDirectory = remotePath
			NSLog("[Belve] Local workingDirectory: \(remotePath)")
		}

		view.environmentVariables = env

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
