import SwiftUI
import SwiftTerm
import AppKit

struct TerminalPaneView: NSViewRepresentable {
	let project: Project
	@EnvironmentObject var notificationStore: NotificationStore

	func makeNSView(context: Context) -> TerminalView {
		let tv = TerminalView(frame: .zero)
		tv.terminalDelegate = context.coordinator
		tv.nativeBackgroundColor = NSColor(Theme.bg)
		tv.nativeForegroundColor = NSColor(Theme.textPrimary)

		context.coordinator.terminalView = tv
		context.coordinator.project = project
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
		var notificationStore: NotificationStore?

		func startShell() {
			guard let tv = terminalView else { return }
			do {
				let pty: PTYService
				if let project = project, project.isDevContainer,
				   let sshHost = project.sshHost,
				   let workspacePath = project.devContainerPath {
					// DevContainer connection
					let args = DevContainerService.exec(sshHost: sshHost, workspacePath: workspacePath)
					NSLog("[Belve] Connecting to DevContainer: \(sshHost):\(workspacePath)")
					pty = try PTYService.spawn(
						shell: args[0],
						args: Array(args.dropFirst())
					)
				} else if let sshHost = project?.sshHost {
					// SSH connection
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
				} else {
					// Local shell
					pty = try PTYService.spawn()
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

				let terminal = tv.getTerminal()
				pty.setSize(cols: terminal.cols, rows: terminal.rows)
				NSLog("[Belve] Shell started for '\(project?.name ?? "unknown")', cols=\(terminal.cols) rows=\(terminal.rows)")
			} catch {
				NSLog("[Belve] Failed to start PTY: \(error)")
			}
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
