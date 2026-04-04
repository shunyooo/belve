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
				.environmentObject(appDelegate.notificationStore)
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
			CommandGroup(after: .newItem) {
				Button("Open Folder...") {
					NotificationCenter.default.post(name: .belveOpenFolder, object: nil)
				}
				.keyboardShortcut("o", modifiers: .command)
			}
			CommandGroup(replacing: .saveItem) {
				Button("Save") {
					NotificationCenter.default.post(name: .belveFileSave, object: nil)
				}
				.keyboardShortcut("s", modifiers: .command)
			}
		}
	}
}

extension Notification.Name {
	static let belveFileSave = Notification.Name("belveFileSave")
	static let belveOpenFolder = Notification.Name("belveOpenFolder")
}

class CommandPaletteState: ObservableObject {
	@Published var isPresented = false
}

class AppDelegate: NSObject, NSApplicationDelegate {
	let commandPaletteState = CommandPaletteState()
	let notificationStore = NotificationStore()

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
		let yOffset = Theme.trafficLightYOffset
		let xOffset = Theme.trafficLightXOffset
		for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
			guard let button = window.standardWindowButton(type) else { continue }
			let defaultX: CGFloat = type == .closeButton ? 7 : (type == .miniaturizeButton ? 27 : 47)
			button.setFrameOrigin(NSPoint(x: defaultX + xOffset, y: button.superview!.frame.height - button.frame.height - yOffset))
		}
	}
}
