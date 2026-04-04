import SwiftUI

@main
struct BelveApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

	var body: some Scene {
		WindowGroup {
			MainWindow()
				.frame(minWidth: 900, minHeight: 500)
				.ignoresSafeArea()
				.environmentObject(appDelegate.commandPaletteState)
		}
		// Window style configured via AppKit in AppDelegate
		.defaultSize(width: 1200, height: 800)
		.commands {
			CommandGroup(after: .toolbar) {
				Button("Command Palette") {
					appDelegate.commandPaletteState.isPresented.toggle()
				}
				.keyboardShortcut("p", modifiers: [.command, .shift])
			}
		}
	}
}

class CommandPaletteState: ObservableObject {
	@Published var isPresented = false
}

class AppDelegate: NSObject, NSApplicationDelegate {
	let commandPaletteState = CommandPaletteState()

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.activate(ignoringOtherApps: true)

		// Configure window like cmux: fullSizeContentView so content starts at y=0
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			guard let window = NSApp.windows.first else { return }
			window.styleMask.insert(.fullSizeContentView)
			window.titlebarAppearsTransparent = true
			window.titleVisibility = .hidden
			window.isMovableByWindowBackground = true
			NSLog("[Belve] Window configured: fullSizeContentView=\(window.styleMask.contains(.fullSizeContentView))")
		}

		NSLog("[Belve] App launched")
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		NSLog("[Belve] App became active")
	}
}
