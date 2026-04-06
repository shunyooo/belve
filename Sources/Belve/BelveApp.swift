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
				.environmentObject(appDelegate.projectStore)
				.environmentObject(appDelegate.notificationStore)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1200, height: 800)
		.commands {
			CommandGroup(after: .toolbar) {
				Button("Command Palette") {
					// Always open in command mode, not folder browser
					NotificationCenter.default.post(name: .belveCommandPalette, object: nil)
				}
				.keyboardShortcut("p", modifiers: [.command, .shift])
			}
			CommandGroup(replacing: .newItem) {
				Button("New Project") {
					NotificationCenter.default.post(name: .belveNewProject, object: nil)
				}
				.keyboardShortcut("n", modifiers: .command)
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
				Button("Reload Project") {
					DispatchQueue.main.async {
						NotificationCenter.default.post(name: .belveReloadProject, object: nil)
					}
				}
				.keyboardShortcut("r", modifiers: .command)
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
				Button("Close Pane") {
					NotificationCenter.default.post(name: .belveClosePane, object: nil)
				}
				.keyboardShortcut("w", modifiers: .command)
			}
			// Cmd+1-9 project switching handled via NSEvent monitor in AppDelegate
		// (SwiftUI CommandGroup + @Published mutation crashes during performKeyEquivalent)
		}
	}
}

extension Notification.Name {
	static let belveFileSave = Notification.Name("belveFileSave")
	static let belveOpenFolder = Notification.Name("belveOpenFolder")
	static let belveSwitchProject = Notification.Name("belveSwitchProject")
	static let belveSplitVertical = Notification.Name("belveSplitVertical")
	static let belveSplitHorizontal = Notification.Name("belveSplitHorizontal")
	static let belveFocusProject = Notification.Name("belveFocusProject")
	static let belveClosePane = Notification.Name("belveClosePane")
	static let belveCommandPalette = Notification.Name("belveCommandPalette")
	static let belveNewProject = Notification.Name("belveNewProject")
	static let belveReloadProject = Notification.Name("belveReloadProject")
}

class CommandPaletteState: ObservableObject {
	@Published var isPresented = false
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	let commandPaletteState = CommandPaletteState()
	let notificationStore = NotificationStore()
	let projectStore = ProjectStore()
	let agentFileMonitor = AgentEventFileMonitor()

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Install crash signal handlers to capture backtrace
		installCrashHandlers()
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

		// Cmd+1-9 project switching via local event monitor
		// (Cannot use SwiftUI CommandGroup — @Published mutation during
		// performKeyEquivalent causes EXC_BAD_ACCESS in swift_retain)
		NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
			guard event.modifierFlags.contains(.command),
				  !event.modifierFlags.contains(.shift),
				  !event.modifierFlags.contains(.option),
				  let chars = event.charactersIgnoringModifiers,
				  let digit = chars.first, digit >= "1" && digit <= "9" else {
				return event
			}
			let index = Int(String(digit))! - 1
			// Perform on next RunLoop iteration to escape event processing stack
			CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
				self?.projectStore.selectByIndex(index)
			}
			CFRunLoopWakeUp(CFRunLoopGetMain())
			return nil // Consume the event
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

	func userNotificationCenter(
		_ center: UNUserNotificationCenter,
		didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		let userInfo = response.notification.request.content.userInfo
		if let projectIdString = userInfo["projectId"] as? String,
		   let projectId = UUID(uuidString: projectIdString) {
			NSLog("[Belve] Notification clicked for project: \(projectId)")
			NSApp.activate(ignoringOtherApps: true)
			NotificationCenter.default.post(
				name: .belveFocusProject,
				object: nil,
				userInfo: ["projectId": projectId]
			)
		}
		completionHandler()
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

	private func installCrashHandlers() {
		let handler: @convention(c) (Int32) -> Void = { signal in
			let trace = Thread.callStackSymbols.joined(separator: "\n")
			let msg = "CRASH signal=\(signal)\n\(trace)\n"
			try? msg.write(toFile: "/tmp/belve-crash-trace.log", atomically: true, encoding: .utf8)
			// Re-raise to get default behavior
			Darwin.signal(signal, SIG_DFL)
			Darwin.raise(signal)
		}
		signal(SIGSEGV, handler)
		signal(SIGBUS, handler)
		signal(SIGABRT, handler)
		signal(SIGILL, handler)
		signal(SIGFPE, handler)
		signal(SIGTRAP, handler)
		atexit {
			let trace = Thread.callStackSymbols.joined(separator: "\n")
			let msg = "EXIT (atexit)\n\(trace)\n"
			try? msg.write(toFile: "/tmp/belve-crash-trace.log", atomically: true, encoding: .utf8)
		}
		NSLog("[Belve] Crash handlers installed")
	}
}
