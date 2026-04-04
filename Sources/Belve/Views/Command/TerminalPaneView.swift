import SwiftUI
import SwiftTerm
import AppKit

/// Terminal view using SwiftTerm for rendering + custom PTYService for process.
struct TerminalPaneView: NSViewRepresentable {
	func makeNSView(context: Context) -> TerminalView {
		let tv = TerminalView(frame: .zero)
		tv.terminalDelegate = context.coordinator

		// Dark theme
		tv.nativeBackgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
		tv.nativeForegroundColor = NSColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1)

		context.coordinator.terminalView = tv

		// Monitor key events to debug
		NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			let isFirstResponder = tv.window?.firstResponder === tv
			NSLog("[Belve] keyDown monitor: '\(event.characters ?? "")' firstResponder=\(isFirstResponder) responder=\(type(of: tv.window?.firstResponder ?? tv))")
			return event
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
			context.coordinator.startShell()
			let result = tv.window?.makeFirstResponder(tv)
			NSLog("[Belve] makeFirstResponder: \(String(describing: result)), actual: \(type(of: tv.window?.firstResponder ?? tv))")
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
				NSLog("[Belve] Shell started successfully")
			} catch {
				NSLog("[Belve] Failed to start PTY: \(error)")
			}
		}

		// MARK: - TerminalViewDelegate

		func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
			ptyService?.setSize(cols: newCols, rows: newRows)
		}

		func send(source: TerminalView, data: ArraySlice<UInt8>) {
			NSLog("[Belve] send called, \(data.count) bytes")
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
