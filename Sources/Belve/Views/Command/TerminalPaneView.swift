import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view using SwiftTerm for rendering + custom PTYService for process.
struct TerminalPaneView: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let container = NSView()
		container.wantsLayer = true
		container.layer?.masksToBounds = true

		let tv = TerminalView(frame: .zero)
		tv.translatesAutoresizingMaskIntoConstraints = false
		tv.wantsLayer = true
		tv.layer?.masksToBounds = true
		tv.terminalDelegate = context.coordinator

		// Dark theme
		tv.nativeBackgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
		tv.nativeForegroundColor = NSColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1)

		container.addSubview(tv)

		NSLayoutConstraint.activate([
			tv.topAnchor.constraint(equalTo: container.topAnchor),
			tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
			tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
		])

		context.coordinator.terminalView = tv

		DispatchQueue.main.async {
			context.coordinator.startShell()
			tv.window?.makeFirstResponder(tv)
		}

		return container
	}

	func updateNSView(_ nsView: NSView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	class Coordinator: NSObject, TerminalViewDelegate {
		weak var terminalView: TerminalView?
		var ptyService: PTYService?

		func startShell() {
			do {
				let pty = try PTYService.spawn()
				self.ptyService = pty

				pty.onData = { [weak self] data in
					let bytes = Array(data)
					self?.terminalView?.feed(byteArray: bytes[0..<bytes.count])
				}

				if let tv = terminalView {
					let terminal = tv.getTerminal()
					pty.setSize(cols: terminal.cols, rows: terminal.rows)
				}
			} catch {
				NSLog("[Belve] Failed to start PTY: \(error)")
			}
		}

		// MARK: - TerminalViewDelegate

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
