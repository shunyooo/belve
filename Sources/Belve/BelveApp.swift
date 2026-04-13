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
				Button("Search Files") {
					NotificationCenter.default.post(name: .belveOpenFileSearch, object: nil)
				}
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
			// Cmd+D/Cmd+Shift+D/Cmd+W handled via .onKeyPress in MainWindow
			// (CommandGroup + @Published mutation crashes during performKeyEquivalent)
			CommandGroup(after: .toolbar) {
				Button("Split Vertical") {}
				Button("Split Horizontal") {}
				Button("Close Pane") {}
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
	static let belveSelectNextProject = Notification.Name("belveSelectNextProject")
	static let belveSelectPreviousProject = Notification.Name("belveSelectPreviousProject")
	static let belveFocusNextPane = Notification.Name("belveFocusNextPane")
	static let belveFocusPreviousPane = Notification.Name("belveFocusPreviousPane")
	static let belveFocusEditor = Notification.Name("belveFocusEditor")
	static let belveToggleEditor = Notification.Name("belveToggleEditor")
	static let belveToggleSidebar = Notification.Name("belveToggleSidebar")
	static let belveToggleFileTree = Notification.Name("belveToggleFileTree")
	static let belveFocusFileTree = Notification.Name("belveFocusFileTree")
	static let belveRevealFileInTree = Notification.Name("belveRevealFileInTree")
	static let belveFileLoadingState = Notification.Name("belveFileLoadingState")
	static let belveOpenFileFromTerminal = Notification.Name("belveOpenFileFromTerminal")
	static let belveOpenFileSearch = Notification.Name("belveOpenFileSearch")
	static let belvePresentFileSearch = Notification.Name("belvePresentFileSearch")
	static let belveTerminalConnectionState = Notification.Name("belveTerminalConnectionState")
	static let belveTerminalConnectionStatus = Notification.Name("belveTerminalConnectionStatus")
	static let belveTerminalRefit = Notification.Name("belveTerminalRefit")
	static let belvePaneClosed = Notification.Name("belvePaneClosed")
	static let belveRefreshFileTree = Notification.Name("belveRefreshFileTree")
	static let belveTerminalDisconnected = Notification.Name("belveTerminalDisconnected")
	static let belveSplitVertical = Notification.Name("belveSplitVertical")
	static let belveSplitHorizontal = Notification.Name("belveSplitHorizontal")
	static let belveFocusProject = Notification.Name("belveFocusProject")
	static let belveClosePane = Notification.Name("belveClosePane")
	static let belveCommandPalette = Notification.Name("belveCommandPalette")
	static let belveNewProject = Notification.Name("belveNewProject")
	static let belveReloadProject = Notification.Name("belveReloadProject")
	static let belveFileDeleted = Notification.Name("belveFileDeleted")
	static let belveUndo = Notification.Name("belveUndo")
}

class CommandPaletteState: ObservableObject {
	@Published var isPresented = false
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
	let commandPaletteState = CommandPaletteState()
	let notificationStore: NotificationStore = {
		let store = NotificationStore()
		store.loadSessions()
		return store
	}()
	let projectStore = ProjectStore()
	private var localKeyMonitor: Any?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Log build info for verifying correct binary is running
		let buildDate = binaryModificationDate()
		NSLog("[Belve] Binary: \(Bundle.main.executableURL?.path ?? "?"), modified: \(buildDate)")

		// Generate launcher script for terminal sessions
		LauncherScriptGenerator.generate()

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

		// Cmd+1-9 handled via .onKeyPress in MainWindow (SwiftUI native)
		localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			guard flags == [.command],
				  event.charactersIgnoringModifiers?.lowercased() == "p" else {
				return event
			}
			NotificationCenter.default.post(name: .belveOpenFileSearch, object: nil)
			return nil
		}

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

	func applicationWillTerminate(_ notification: Notification) {
		if let localKeyMonitor {
			NSEvent.removeMonitor(localKeyMonitor)
		}
	}

	func applicationDidBecomeActive(_ notification: Notification) {
		NSLog("[Belve] App became active")
		adjustTrafficLights()
		// Refresh git status + file tree when app regains focus
		projectStore.refreshGitStatus()
		NotificationCenter.default.post(name: .belveRefreshFileTree, object: nil)
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

	private func binaryModificationDate() -> String {
		guard let url = Bundle.main.executableURL,
			  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
			  let date = attrs[.modificationDate] as? Date else { return "unknown" }
		let fmt = DateFormatter()
		fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
		return fmt.string(from: date)
	}
}
