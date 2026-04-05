import SwiftUI
import SwiftTerm
import AppKit

struct TerminalPaneView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	@EnvironmentObject var notificationStore: NotificationStore

	func makeNSView(context: Context) -> TerminalView {
		let tv = TerminalView(frame: .zero)
		tv.terminalDelegate = context.coordinator
		tv.nativeBackgroundColor = NSColor(Theme.bg)
		tv.nativeForegroundColor = NSColor(Theme.textPrimary)

		context.coordinator.terminalView = tv
		context.coordinator.project = project
		context.coordinator.paneId = paneId
		context.coordinator.notificationStore = notificationStore

		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			context.coordinator.startShell()
			tv.window?.makeFirstResponder(tv)
		}

		return tv
	}

	func updateNSView(_ nsView: TerminalView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	class Coordinator: NSObject, TerminalViewDelegate {
		weak var terminalView: TerminalView?
		var ptyService: PTYService?
		var project: Project?
		var paneId: String?
		var notificationStore: NotificationStore?

		func startShell() {
			guard let tv = terminalView else { return }
			do {
				let pty: PTYService
				if let project = project, project.isDevContainer,
				   let sshHost = project.sshHost,
				   let workspacePath = project.devContainerPath {
					// DevContainer connection - deploy Belve CLI first
					BelveRemoteInstaller.deploy(to: sshHost)
					let args = DevContainerService.exec(sshHost: sshHost, workspacePath: workspacePath)
					NSLog("[Belve] Connecting to DevContainer: \(sshHost):\(workspacePath)")
					pty = try PTYService.spawn(
						shell: args[0],
						args: Array(args.dropFirst())
					)
					// Inject Belve environment on remote
					sendRemoteBelveEnv(pty: pty)
				} else if let sshHost = project?.sshHost {
					// SSH connection - deploy Belve CLI first
					BelveRemoteInstaller.deploy(to: sshHost)
					NSLog("[Belve] Connecting to SSH host: \(sshHost)")
					pty = try PTYService.spawn(
						shell: "/usr/bin/ssh",
						args: [
							"-o", "StrictHostKeyChecking=accept-new",
							"-o", "ServerAliveInterval=30",
							"-t",
							sshHost,
						]
					)
					// Inject Belve environment on remote
					sendRemoteBelveEnv(pty: pty)
				} else {
					// Local shell with Belve environment
					let belveEnv = buildBelveEnvironment()
					pty = try PTYService.spawn(environment: belveEnv)
					// Shell rc files (.zshrc, .bashrc) often override PATH, so
					// re-inject Belve bin dir after shell init completes.
					// Leading space prevents adding to shell history (HISTCONTROL=ignorespace).
					if let binDir = belveEnv["PATH"]?.components(separatedBy: ":").first {
						DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
							pty.send(" export PATH=\"\(binDir):$PATH\" && clear\n")
						}
					}
				}
				self.ptyService = pty

				pty.onData = { [weak self] data in
					let bytes = Array(data)
					self?.terminalView?.feed(byteArray: bytes[0..<bytes.count])
				}

				pty.onNotification = { [weak self] title, body in
					guard let projectId = self?.project?.id else { return }
					self?.notificationStore?.add(projectId: projectId, title: title, body: body)
				}

				// Agent status via OSC transport
				if let paneId = paneId, let projectId = project?.id {
					notificationStore?.registerPane(paneId: paneId, projectId: projectId)
					pty.agentTransport.onAgentStatus = { [weak self] pId, status, message in
						self?.notificationStore?.updateAgentStatus(paneId: pId, status: status, message: message)
					}
				}

				let terminal = tv.getTerminal()
				pty.setSize(cols: terminal.cols, rows: terminal.rows)
				NSLog("[Belve] Shell started for '\(project?.name ?? "unknown")', cols=\(terminal.cols) rows=\(terminal.rows)")
			} catch {
				NSLog("[Belve] Failed to start PTY: \(error)")
			}
		}

		private func sendRemoteBelveEnv(pty: PTYService) {
			// Send environment setup command after SSH connects
			let pId = paneId ?? "unknown"
			let projectId = project?.id.uuidString ?? "unknown"
			DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
				pty.send("export BELVE_SESSION=1 BELVE_PANE_ID=\(pId) BELVE_PROJECT_ID=\(projectId) PATH=~/.belve/bin:$PATH\n")
			}
		}

		private func buildBelveEnvironment() -> [String: String] {
			var env: [String: String] = [
				"BELVE_SESSION": "1",
			]
			if let paneId = paneId {
				env["BELVE_PANE_ID"] = paneId
			}
			if let projectId = project?.id {
				env["BELVE_PROJECT_ID"] = projectId.uuidString
			}
			// Add Belve's bin directory to PATH for claude wrapper
			let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
			let resourceBin = execDir?
				.deletingLastPathComponent()
				.appendingPathComponent("Resources/bin")
			if let binPath = resourceBin?.path {
				let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
				env["PATH"] = "\(binPath):\(currentPath)"
			}
			return env
		}

		func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
			ptyService?.setSize(cols: newCols, rows: newRows)
		}

		func send(source: TerminalView, data: ArraySlice<UInt8>) {
			ptyService?.send(Data(data))
		}

		func scrolled(source: TerminalView, position: Double) {}
		func setTerminalTitle(source: TerminalView, title: String) {}
		func setTerminalIconTitle(source: TerminalView, title: String) {}
		func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
		func clipboardCopy(source: TerminalView, content: Data) {
			if let str = String(data: content, encoding: .utf8) {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(str, forType: .string)
			}
		}
		func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
		func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
		func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
	}
}
