import SwiftUI
import AppKit
import Carbon.HIToolbox
import UserNotifications

/// Belve.app プロセス起動時刻。startup grace 用 (起動直後の自動 focus 抑制等)。
enum BelveAppStart {
	static let date = Date()
}

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
				Button("Toggle Tile View") {
					NotificationCenter.default.post(name: .belveToggleTile, object: nil)
				}
				.keyboardShortcut("t", modifiers: .command)
				Button("Toggle Stage View") {
					NotificationCenter.default.post(name: .belveToggleStage, object: nil)
				}
				.keyboardShortcut("y", modifiers: .command)
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
	static let belveEditorWebViewDidFocus = Notification.Name("belveEditorWebViewDidFocus")
	static let belveTerminalFocused = Notification.Name("belveTerminalFocused")
	static let belveFileTreeFocused = Notification.Name("belveFileTreeFocused")
	static let belveRevealFileInTree = Notification.Name("belveRevealFileInTree")
	static let belveFileLoadingState = Notification.Name("belveFileLoadingState")
	static let belveOpenFileFromTerminal = Notification.Name("belveOpenFileFromTerminal")
	static let belveOpenFileSearch = Notification.Name("belveOpenFileSearch")
	static let belvePresentFileSearch = Notification.Name("belvePresentFileSearch")
	static let belveTerminalConnectionState = Notification.Name("belveTerminalConnectionState")
	static let belveTerminalConnectionStatus = Notification.Name("belveTerminalConnectionStatus")
	static let belveProjectConnectionError = Notification.Name("belveProjectConnectionError")
	static let belveTerminalRefit = Notification.Name("belveTerminalRefit")
	static let belvePaneClosed = Notification.Name("belvePaneClosed")
	static let belveRefreshFileTree = Notification.Name("belveRefreshFileTree")
	static let belveOpenSettings = Notification.Name("belveOpenSettings")
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
	static let belvePortDetected = Notification.Name("belvePortDetected")
	static let belveToggleBrowser = Notification.Name("belveToggleBrowser")
	static let belveToggleTile = Notification.Name("belveToggleTile")
	static let belveTileOpenFocused = Notification.Name("belveTileOpenFocused")
	static let belveToggleStage = Notification.Name("belveToggleStage")
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

		// Disable macOS window tabbing — reserves Cmd+Shift+\ for "Show Tab Tile"
		// which conflicts with Belve's session bar toggle shortcut.
		NSWindow.allowsAutomaticWindowTabbing = false

		// Close duplicate main windows (can appear if restoration brings back tab-group state).
		DispatchQueue.main.async {
			let mainWindows = NSApp.windows.filter { $0.contentViewController != nil && $0.isVisible }
			if mainWindows.count > 1 {
				for window in mainWindows.dropFirst() {
					window.close()
				}
			}
		}

		// Phase 3 移行: SSH master / port forward は master daemon が常駐管理する。
		// Belve.app 起動時に stale 掃除 (cleanupStaleBelveProcesses) や teardownAll を
		// 呼ぶと master の管理する SSH socket まで kill してしまう。Master が
		// 既存の場合は触らず attach するのが正しい。Stale 掃除は master daemon
		// 側 (起動時の os.Remove(socketPath) と既存 master 検知ロジック) に任せる。
		// 残すのは「per-pane の local belve-persist client (tcpbackend)」と「stale
		// session sock file」だけ。これらは master ではなく launcher 経由で生まれる
		// もので、Belve.app 死亡で reorganize される。
		Self.cleanupStaleBelveProcesses()

		// Phase 1 (mac master daemon): bootstrap before anything else that might
		// want to talk to it. Launches `belve-persist -mac-master` if not already
		// running, attaches via /tmp/belve-master.sock, version-handshakes.
		// 失敗しても今は致命的ではない (まだ master を実際に使ってる経路が無い)
		// ので NSLog で握り潰し、existing path で継続する。Phase 2+ で必須化。
		// Master daemon を bootstrap してから setupAllRemoteRPC を走らせる。
		// 順序が重要: setupRemoteRPC が master.ensureSetup を呼ぶので、master
		// が ready でないと先頭の数個が connection lost で fall back する。
		Task.detached(priority: .userInitiated) { [projectStore] in
			do {
				let v = try await MasterClient.shared.bootstrap()
				NSLog("[Belve][master] bootstrap ok version=%@", v)
			} catch {
				NSLog("[Belve][master] bootstrap failed: %@", error.localizedDescription)
			}
			await MainActor.run {
				projectStore.setupAllRemoteRPC()
			}
		}

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

		// Global hotkey: Cmd+Shift+. to toggle app visibility
		// Uses Carbon RegisterEventHotKey — no Accessibility permission needed.
		registerGlobalHotkey()

		// Cmd+1-9 handled via .onKeyPress in MainWindow (SwiftUI native)
		localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
			let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
			// Accept Cmd or Cmd+Shift (reject Cmd+Option/Ctrl which aren't our shortcuts).
			guard flags.contains(.command),
				  flags.subtracting([.command, .shift]).isEmpty,
				  let key = event.charactersIgnoringModifiers?.lowercased() else {
				return event
			}
			let shift = flags.contains(.shift)
			// Cmd+Enter (keyCode 36): tile mode で focus 中 pane の project view へ遷移。
			if event.keyCode == 36, !shift, AppConfig.shared.viewMode == .tile {
				NotificationCenter.default.post(name: .belveTileOpenFocused, object: nil)
				return nil
			}
			switch key {
			// Keys that accept both Cmd and Cmd+Shift variants
			case "e":
				if shift {
					NotificationCenter.default.post(name: .belveToggleFileTree, object: nil)
				} else {
					NotificationCenter.default.post(name: .belveToggleEditor, object: nil)
				}
				return nil
			case "b" where shift:
				NotificationCenter.default.post(name: .belveToggleBrowser, object: nil)
				return nil
			case ".", ">" where shift:
				NSApp.hide(nil)
				return nil
			case "\\" where !shift:
				if AppConfig.shared.viewMode.isDedicatedView { return nil }
				NotificationCenter.default.post(name: .belveToggleSidebar, object: nil)
				return nil
			case "p":
				if shift {
					NotificationCenter.default.post(name: .belveCommandPalette, object: nil)
				} else {
					NotificationCenter.default.post(name: .belveOpenFileSearch, object: nil)
				}
				return nil
			// Cmd-only keys — pass through if Shift is held
			case "'" where !shift:
				NotificationCenter.default.post(name: .belveFocusNextPane, object: nil)
				return nil
			case ";" where !shift:
				NotificationCenter.default.post(name: .belveFocusPreviousPane, object: nil)
				return nil
			case "]" where !shift:
				if AppConfig.shared.viewMode.isDedicatedView { return nil }
				NotificationCenter.default.post(name: .belveSelectNextProject, object: nil)
				return nil
			case "[" where !shift:
				if AppConfig.shared.viewMode.isDedicatedView { return nil }
				NotificationCenter.default.post(name: .belveSelectPreviousProject, object: nil)
				return nil
			case "1", "2", "3", "4", "5", "6", "7", "8", "9":
				if shift { return event }
				if AppConfig.shared.viewMode.isDedicatedView { return nil }
				if let digit = Int(key) {
					NotificationCenter.default.post(
						name: .belveSwitchProject,
						object: nil,
						userInfo: ["index": digit - 1]
					)
				}
				return nil
			case "," where !shift:
				NotificationCenter.default.post(name: .belveOpenSettings, object: nil)
				return nil
			case "o" where !shift:
				NotificationCenter.default.post(name: .belveOpenFolder, object: nil)
				return nil
			case "t" where !shift:
				NotificationCenter.default.post(name: .belveToggleTile, object: nil)
				return nil
			case "y" where !shift:
				NotificationCenter.default.post(name: .belveToggleStage, object: nil)
				return nil
			case "-", "_":
				AppConfig.shared.terminalFontSize -= 1
				return nil
			case "=", "+":
				AppConfig.shared.terminalFontSize += 1
				return nil
			case "0" where !shift:
				AppConfig.shared.terminalFontSize = 13
				return nil
			case "r" where !shift:
				// Cmd+R routes to the browser when its panel is the key window
				// (matches the obvious "this is a browser, reload it" mental
				// model); otherwise fall back to project reload.
				if NSApp.keyWindow?.identifier?.rawValue.hasPrefix("BelveBrowser-") == true {
					NotificationCenter.default.post(
						name: .belveBrowserNav,
						object: nil,
						userInfo: ["action": BrowserView.NavAction.reload]
					)
				} else {
					NotificationCenter.default.post(name: .belveReloadProject, object: nil)
				}
				return nil
			default:
				return event
			}
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
		SSHTunnelManager.shared.teardownAll()
		Self.cleanupStaleBelveProcesses()
	}

	/// Stale process / socket cleanup. Runs on app start/exit.
	///
	/// Important: **local persist daemons (= per-pane PTY holders) は kill しない**。
	/// Belve.app を再起動した時に既存セッション (zsh + history + 起動中プロセス) を
	/// 復元するため、これらは生かしたままにして launcher の tryAttach が拾う。
	///
	/// 代わりに **orphan reap** で対応: pane-layouts.json に登場しない (= もう
	/// どの project も使ってない) socket だけを kill して、ゾンビ蓄積を防ぐ。
	///
	/// Skipped if another Belve instance is running — those processes belong to it.
	static func cleanupStaleBelveProcesses() {
		if otherBelveInstancesRunning() {
			NSLog("[Belve] cleanupStaleBelveProcesses skipped — other Belve instance(s) active")
			return
		}
		// belve-persist は env BELVE_PARENT_PID に従って自分で parent (Belve.app)
		// 死活監視 → 自殺するようになった (構造改善 A)。なのでここでは念のため
		// 残ってる client プロセスを kill する程度で良い。
		// - mac-master は除外 (Belve 死後も生きて欲しい、MasterClient.bootstrap が
		//   version 確認して必要なら kill+respawn する)
		// - 万一 watchParent loop がまだ 1s ポーリングを終えてない瞬間でも
		//   ここで client が掃除されるので belt-and-suspenders。
		// - daemon (-daemon flag) は触らない。layout に紐づく session 保持のため。
		//   layout から外れたものだけ reapOrphanLocalDaemons が掃除する。
		killOrphanClients()
		reapOrphanLocalDaemons()
		NSLog("[Belve] cleanupStaleBelveProcesses done")
	}

	/// Daemon でも mac-master でもない belve-persist プロセス (= client) を kill。
	/// 新 Belve.app が tryAttach で再 spawn する。watchParent が動いてれば自殺
	/// するはずだが、そのポーリング間隔 (1s) より早く新 Belve が起動した時の保険。
	private static func killOrphanClients() {
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
		proc.arguments = ["-fl", "belve-persist-darwin"]
		let pipe = Pipe()
		proc.standardOutput = pipe
		proc.standardError = FileHandle.nullDevice
		do { try proc.run() } catch { return }
		proc.waitUntilExit()
		guard let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return }
		for line in raw.split(separator: "\n") {
			let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
			guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
			let cmd = String(parts[1])
			if cmd.contains("-mac-master") { continue }
			if cmd.contains(" -daemon ") { continue }
			kill(pid, SIGTERM)
		}
	}

	private static func runShell(_ script: String) {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/bin/sh")
		p.arguments = ["-c", script]
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		try? p.run()
		p.waitUntilExit()
	}

	/// pane-layouts.json から「現在 project layout に存在する pane」 set を作り、
	/// /tmp/belve-shell/sessions/belve-*.sock のうち未参照のものだけを kill する。
	/// 残骸 .pid / .ver も合わせて掃除。
	private static func reapOrphanLocalDaemons() {
		let sessionsDir = "/tmp/belve-shell/sessions"
		let fm = FileManager.default
		guard let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
		let expected = expectedLocalSessionNames()
		for entry in entries where entry.hasPrefix("belve-") && entry.hasSuffix(".sock") {
			let sessName = String(entry.dropLast(".sock".count))  // "belve-XXXXXXXX[-N]"
			if expected.contains(sessName) {
				continue  // 生かす — launcher が tryAttach で再利用する
			}
			NSLog("[Belve] reap orphan local daemon: %@", sessName)
			let sockPath = "\(sessionsDir)/\(entry)"
			// daemon プロセスを kill (= -socket で sockPath に紐づく persist procs)
			runShell("pkill -f 'belve-persist-darwin.*\(sockPath)' 2>/dev/null; true")
			try? fm.removeItem(atPath: sockPath)
			try? fm.removeItem(atPath: sockPath + ".pid")
			try? fm.removeItem(atPath: "\(sessionsDir)/\(sessName).ver")
		}
	}

	/// pane-layouts.json (CommandAreaStateManager の永続化先) を読んで、
	/// 全 project の全 leaf pane の (projShort, paneIndex) から期待される
	/// session 名 set を組み立てる。
	private static func expectedLocalSessionNames() -> Set<String> {
		var result: Set<String> = []
		let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
		let layoutURL = appSupport?
			.appendingPathComponent("Belve")
			.appendingPathComponent("pane-layouts.json")
		guard let url = layoutURL,
		      let data = try? Data(contentsOf: url),
		      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return result }
		for (projectIDString, root) in json {
			let projShort = String(projectIDString.prefix(8)).uppercased()
			collectPaneSessions(node: root, projShort: projShort, into: &result)
		}
		return result
	}

	private static func collectPaneSessions(node: Any, projShort: String, into result: inout Set<String>) {
		guard let dict = node as? [String: Any] else { return }
		if let children = dict["children"] as? [Any] {
			for c in children {
				collectPaneSessions(node: c, projShort: projShort, into: &result)
			}
			return
		}
		// leaf node — 持ってる paneIndex で session 名を組む
		if let idx = dict["paneIndex"] as? Int {
			let name = idx == 0 ? "belve-\(projShort)" : "belve-\(projShort)-\(idx)"
			result.insert(name)
		}
	}

	/// True if at least one Belve executable other than us is currently running.
	private static func otherBelveInstancesRunning() -> Bool {
		let mypid = ProcessInfo.processInfo.processIdentifier
		let pgrep = Process()
		pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
		pgrep.arguments = ["-f", "MacOS/Belve$"]
		let pipe = Pipe()
		pgrep.standardOutput = pipe
		pgrep.standardError = FileHandle.nullDevice
		do {
			try pgrep.run()
		} catch {
			return false
		}
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		pgrep.waitUntilExit()
		let output = String(data: data, encoding: .utf8) ?? ""
		let others = output
			.split(separator: "\n")
			.compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
			.filter { $0 != mypid }
		return !others.isEmpty
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

	// MARK: - Global Hotkey (Carbon, no Accessibility needed)

	private var hotKeyRef: EventHotKeyRef?

	private func registerGlobalHotkey() {
		// keyCode 47 = "." key, cmdKey + shiftKey modifiers
		let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
		let keyCode: UInt32 = 47
		var hotKeyID = EventHotKeyID(signature: OSType(0x424C5645), id: 1) // "BLVE"

		let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
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
			return noErr
		}

		var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, nil, nil)
		RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
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
