import SwiftUI
import SwiftTerm

struct TerminalPaneView: NSViewRepresentable {
	func makeNSView(context: Context) -> LocalProcessTerminalView {
		let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
		tv.processDelegate = context.coordinator

		// Dark theme colors
		let bg = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
		let fg = NSColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1)
		tv.nativeBackgroundColor = bg
		tv.nativeForegroundColor = fg
		// Terminal colors set via nativeBackgroundColor/nativeForegroundColor above

		// Start shell asynchronously to avoid blocking
		DispatchQueue.main.async {
			tv.startProcess()
		}
		return tv
	}

	func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
		func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
		func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
		func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
		func processTerminated(source: TerminalView, exitCode: Int32?) {}
	}
}
