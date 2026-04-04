import SwiftUI
import AppKit

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
		.windowStyle(.hiddenTitleBar)
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
		adjustTrafficLights()

		NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.adjustTrafficLights()
		}
		NotificationCenter.default.addObserver(
			forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
		) { [weak self] _ in
			self?.adjustTrafficLights()
		}

		NSLog("[Belve] App launched")
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		NSLog("[Belve] App became active")
		adjustTrafficLights()
	}

	private func adjustTrafficLights() {
		guard let window = NSApp.windows.first else { return }
		let yOffset: CGFloat = 10
		let xOffset: CGFloat = 6
		for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
			guard let button = window.standardWindowButton(type) else { continue }
			let defaultX: CGFloat = type == .closeButton ? 7 : (type == .miniaturizeButton ? 27 : 47)
			button.setFrameOrigin(NSPoint(x: defaultX + xOffset, y: button.superview!.frame.height - button.frame.height - yOffset))
		}
	}
}
