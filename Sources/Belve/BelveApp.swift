import SwiftUI
import AppKit
import UserNotifications

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
			CommandGroup(after: .toolbar) {
				Button("Split Vertical") {
					NotificationCenter.default.post(name: .belveSplitVertical, object: nil)
				}
				.keyboardShortcut("d", modifiers: .command)
				Button("Split Horizontal") {
					NotificationCenter.default.post(name: .belveSplitHorizontal, object: nil)
				}
				.keyboardShortcut("d", modifiers: [.command, .shift])
			}
			CommandGroup(after: .toolbar) {
				ForEach(1...9, id: \.self) { index in
					Button("Switch to Project \(index)") {
						NotificationCenter.default.post(
							name: .belveSwitchProject,
							object: nil,
							userInfo: ["index": index - 1]
						)
					}
					.keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
				}
			}
		}
	}
}

extension Notification.Name {
	static let belveFileSave = Notification.Name("belveFileSave")
	static let belveOpenFolder = Notification.Name("belveOpenFolder")
	static let belveSwitchProject = Notification.Name("belveSwitchProject")
	static let belveSplitVertical = Notification.Name("belveSplitVertical")
	static let belveSplitHorizontal = Notification.Name("belveSplitHorizontal")
}

class CommandPaletteState: ObservableObject {
	@Published var isPresented = false
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	let commandPaletteState = CommandPaletteState()
	let notificationStore = NotificationStore()
	let agentFileMonitor = AgentEventFileMonitor()

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSApp.activate(ignoringOtherApps: true)
		adjustTrafficLights()

		// Set notification delegate (must be before requestAuthorization)
		UNUserNotificationCenter.current().delegate = self

		// Request notification permission
		notificationStore.requestNotificationPermission()

		// Global hotkey: Cmd+' to toggle app visibility
		NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
			if event.modifierFlags.contains(.command),
			   event.charactersIgnoringModifiers == "'" {
				DispatchQueue.main.async {
					if NSApp.isHidden {
						NSApp.unhide(nil)
						NSApp.activate(ignoringOtherApps: true)
					} else if NSApp.isActive {
						NSApp.hide(nil)
					} else {
						NSApp.activate(ignoringOtherApps: true)
					}
				}
			}
		}

		// Start monitoring agent events file
		agentFileMonitor.onEvent = { [weak self] paneId, status, message in
			self?.notificationStore.updateAgentStatus(paneId: paneId, status: status, message: message)
		}
		agentFileMonitor.start()

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

	// MARK: - UNUserNotificationCenterDelegate

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		// Show banner + sound even when app is in foreground
		completionHandler([.banner, .sound])
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
