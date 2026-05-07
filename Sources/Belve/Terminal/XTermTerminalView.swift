import SwiftUI
import WebKit
import Combine

/// Auto-focus 制御の global 状態。
/// - `lastAutoFocusAt`: 直前 auto-focus 時刻 (debounce 用)。
/// - `didAutoFocusSinceLaunch`: Belve 起動後に 1 度でも auto-focus したか。
///   起動直後の集中 spawn 期間中は「先着 1 個だけ」focus してそれ以降は奪わない。
enum TerminalFocusGate {
	static var lastAutoFocusAt: Date = .distantPast
	static var didAutoFocusSinceLaunch: Bool = false
}

final class TerminalWebView: WKWebView {
	var onCopyCommand: (() -> Void)?
	var onPasteCommand: (() -> Void)?
	var onLineDeleteCommand: (() -> Void)?
	var onMetaKeyChanged: ((Bool) -> Void)?
	var onMouseFocus: (() -> Void)?
	/// true の時、自分が first responder で無い時の scroll event は親 NSView に
	/// 流す (= 内部 terminal scrollback ではなく外側 ScrollView をスクロールさせる)。
	/// Tile view で「focus してない pane の上で scroll → gallery 全体スクロール」用。
	var forwardsScrollWhenNotFocused: Bool = false

	override var acceptsFirstResponder: Bool { true }

	override func scrollWheel(with event: NSEvent) {
		if forwardsScrollWhenNotFocused, window?.firstResponder !== self {
			nextResponder?.scrollWheel(with: event)
			return
		}
		super.scrollWheel(with: event)
	}

	override func becomeFirstResponder() -> Bool {
		NotificationCenter.default.post(name: .belveTerminalFocused, object: self)
		return super.becomeFirstResponder()
	}

	override func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Only handle Cmd+C/V if this webview (or a child) is the first responder
		guard let firstResponder = window?.firstResponder as? NSView,
			  firstResponder === self || firstResponder.isDescendant(of: self) || isAncestor(of: firstResponder)
		else {
			return super.performKeyEquivalent(with: event)
		}

		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		NSLog(
			"[Belve][keys] performKeyEquivalent chars=%@ ignoring=%@ keyCode=%d flags=%@",
			event.characters ?? "nil",
			event.charactersIgnoringModifiers ?? "nil",
			event.keyCode,
			String(describing: flags)
		)
		guard flags == [.command],
			  let key = event.charactersIgnoringModifiers?.lowercased() else {
			return super.performKeyEquivalent(with: event)
		}

		switch key {
		case "c":
			onCopyCommand?()
			return true
		case "v":
			onPasteCommand?()
			return true
		case String(UnicodeScalar(NSDeleteCharacter)!):
			onLineDeleteCommand?()
			return true
		default:
			if event.keyCode == 51 {
				onLineDeleteCommand?()
				return true
			}
			return super.performKeyEquivalent(with: event)
		}
	}

	private func isAncestor(of view: NSView?) -> Bool {
		guard let view else { return false }
		var current: NSView? = view
		while let c = current {
			if c === self { return true }
			current = c.superview
		}
		return false
	}

	override func flagsChanged(with event: NSEvent) {
		let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		onMetaKeyChanged?(flags.contains(.command))
		super.flagsChanged(with: event)
	}

	override func mouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.mouseDown(with: event)
	}

	override func rightMouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.rightMouseDown(with: event)
	}

	override func otherMouseDown(with event: NSEvent) {
		onMouseFocus?()
		super.otherMouseDown(with: event)
	}



}

/// SwiftUI wrapper for xterm.js running in WKWebView.
struct XTermTerminalView: NSViewRepresentable {
	let project: Project
	var paneId: String?
	var paneIndex: Int = 0
	var viewWidth: CGFloat = 0
	var viewHeight: CGFloat = 0
	/// この project が現在 sidebar で選択中か。非選択時は auto-focus を抑制する
	/// (= 全 project が ZStack で同時 mount されてるので、非選択 project の
	/// updateNSView が触ると現在の active pane から focus を奪う事象を防ぐ)。
	var isProjectSelected: Bool = true
	@EnvironmentObject var notificationStore: NotificationStore
	@EnvironmentObject var commandAreaState: CommandAreaState

	func makeNSView(context: Context) -> WKWebView {
		// Pane registry を経由: 同じ paneId で既存 WebView あれば再利用 (= tile view と
		// project view 間で同じ WebView インスタンスを reparent しながら共有)。
		// 既存 entry の場合は coordinator も registry が strong に保持してるので、SwiftUI の
		// 新規 context.coordinator は使わず、callback bind / PTY setup も skip。
		let resolvedPaneId = paneId
		let createPair: () -> (WKWebView, AnyObject) = {
			let config = WKWebViewConfiguration()
			config.userContentController.add(context.coordinator, name: "terminalHandler")

			let initialFrame = NSRect(x: 0, y: 0, width: max(1, viewWidth), height: max(1, viewHeight))
			let webView = TerminalWebView(frame: initialFrame, configuration: config)
			webView.autoresizingMask = [.width, .height]
			let terminalIdentifier = resolvedPaneId.map { "BelveTerminalWebView:\($0)" } ?? "BelveTerminalWebView"
			webView.identifier = NSUserInterfaceItemIdentifier(terminalIdentifier)
			webView.setValue(false, forKey: "drawsBackground")
			webView.onCopyCommand = { [weak coordinator = context.coordinator] in
				coordinator?.copySelectionToPasteboard()
			}
			webView.onPasteCommand = { [weak coordinator = context.coordinator] in
				coordinator?.pasteFromPasteboard()
			}
			webView.onLineDeleteCommand = { [weak coordinator = context.coordinator] in
				coordinator?.sendLineDelete()
			}
			webView.onMetaKeyChanged = { [weak coordinator = context.coordinator] isPressed in
				coordinator?.setMetaPressed(isPressed)
			}
			webView.onMouseFocus = { [weak coordinator = context.coordinator] in
				coordinator?.activatePane()
			}
			if let html = Self.buildHTML() {
				webView.loadHTMLString(html, baseURL: nil)
			}
			return (webView, context.coordinator)
		}

		let webView: WKWebView
		let isNewlyCreated: Bool
		if let paneId {
			let result = PaneHostRegistry.shared.resolveWebView(
				forPaneId: paneId,
				projectId: project.id,
				paneIndex: paneIndex,
				create: createPair
			)
			webView = result.webView
			isNewlyCreated = result.isNewlyCreated
		} else {
			let (newWebView, _) = createPair()
			webView = newWebView
			isNewlyCreated = true
		}

		// SwiftUI 側 context.coordinator のフィールドは毎回 setup する。
		// registry が再利用する WebView でも、updateNSView は新 coordinator の
		// resizeTerminal() を呼ぶので、webView ref が無いと resize が no-op になる。
		// (callback bindings は WebView 上に既に新規生成時に設定済みなので、
		//  ここで再 bind はしない。)
		context.coordinator.webView = webView
		context.coordinator.project = project
		context.coordinator.paneId = paneId
		context.coordinator.paneIndex = paneIndex
		context.coordinator.notificationStore = notificationStore
		context.coordinator.commandAreaState = commandAreaState

		// Pane mapping と observer 登録は新規生成時のみ (重複登録防止)。
		if isNewlyCreated {
			if let paneId {
				notificationStore.registerPane(paneId: paneId, projectId: project.id)
			}

			context.coordinator.refitObserver = NotificationCenter.default.addObserver(
				forName: .belveTerminalRefit, object: nil, queue: .main
			) { [weak coordinator = context.coordinator] notif in
				guard let coordinator,
					  let projectId = notif.userInfo?["projectId"] as? UUID,
					  coordinator.project?.id == projectId else { return }
				coordinator.performRefit()
			}
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		// resizeTerminal 等の操作は registry に保存された "primary" coordinator (= WebView と
		// 一緒に最初に mount された方) に流す。新しい SwiftUI mount で生成された
		// context.coordinator には isTerminalReady / ptyService 等の state が無いため
		// (handler が primary に bind されてる)、ここで使うと no-op になる。
		let activeCoord: Coordinator = {
			if let paneId,
			   let entry = PaneHostRegistry.shared.entries[paneId],
			   let primary = entry.coordinator as? Coordinator {
				return primary
			}
			return context.coordinator
		}()

		if viewWidth > 0, viewHeight > 0 {
			let newFrame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
			if nsView.frame.size != newFrame.size {
				NSLog("[Belve] updateNSView pane=%@ viewW=%.0f viewH=%.0f oldW=%.0f oldH=%.0f",
					  paneId ?? "?", viewWidth, viewHeight, nsView.frame.width, nsView.frame.height)
				nsView.frame = newFrame
			}
			activeCoord.resizeTerminal(width: viewWidth, height: viewHeight)
		}
		// Tile view (= isProjectSelected が false で mount される) の時は、focus してない
		// pane の scroll を親 ScrollView に流す。Project view では従来通り pane 内 scroll。
		if let term = nsView as? TerminalWebView {
			term.forwardsScrollWhenNotFocused = !isProjectSelected
		}
		// Focus は CommandAreaState.activePaneId が source of truth (構造改善 C)。
		// 加えて isProjectSelected で「現在 sidebar で選択中の project」のみ focus
		// 取得対象にする (= 全 project ZStack 同時 mount による誤 focus 奪取を防ぐ)。
		if isProjectSelected,
		   let paneId, let active = commandAreaState.activePaneId,
		   active.uuidString == paneId,
		   nsView.window?.firstResponder !== nsView,
		   activeCoord.isTerminalReady {
			DispatchQueue.main.async {
				nsView.window?.makeFirstResponder(nsView)
				nsView.evaluateJavaScript("terminalFocus(true)", completionHandler: nil)
			}
		}
	}

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	static func buildHTML() -> String? {
		let execDir = Bundle.main.executableURL!.deletingLastPathComponent()
		let bundlePath = execDir.appendingPathComponent("Belve_Belve.bundle/Contents/Resources/Resources")
		let fallbackPath = execDir
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Belve/Resources")

		let resourceDir = FileManager.default.fileExists(atPath: bundlePath.path) ? bundlePath : fallbackPath

		guard let htmlTemplate = try? String(contentsOf: resourceDir.appendingPathComponent("terminal.html")),
			  let js = try? String(contentsOf: resourceDir.appendingPathComponent("terminal-bundle.js")),
			  let css = try? String(contentsOf: resourceDir.appendingPathComponent("xterm.css"))
		else {
			NSLog("[Belve] Failed to load terminal resources from \(bundlePath.path) or \(fallbackPath.path)")
			return nil
		}

		return htmlTemplate
			.replacingOccurrences(of: "/* XTERM_CSS */", with: css)
			.replacingOccurrences(of: "/* TERMINAL_JS */", with: js)
	}

	// MARK: - Coordinator

	class Coordinator: NSObject, WKScriptMessageHandler {
		weak var webView: WKWebView?
		var project: Project?
		var paneId: String?
		var paneIndex: Int = 0
		var ptyService: PTYService?
		weak var notificationStore: NotificationStore?
		var refitObserver: Any?
		weak var commandAreaState: CommandAreaState?
		var fontSizeCancellable: AnyCancellable?

		/// Buffer PTY output and flush on a timer to avoid excessive JS calls
		private var outputBuffer = Data()
		private var statusScanBuffer = Data()
		private var flushTimer: Timer?
		private var isWaitingForInitialOutput = false
		var isTerminalReady = false
		private var isShowingTransientStatus = false
		/// xterm 起動 (ready) 時点で auto-focus を保留しておくフラグ。
		/// 「first PTY output 到着 = 接続確立」のタイミングまで focus を遅延し、
		/// 接続前のペインに focus が奪われて入力が消える事象を防ぐ。
		private var pendingAutoFocus = false

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				// xterm.js が起動した。ただしこの時点で PTY は未接続の可能性 (= remote
				// なら SSH setup 中)。focus は「first PTY output 到着」(= 真に接続確立)
				// まで保留して bufferOutput 側で発火させる。これで未接続ペインに focus
				// が奪われる問題を解消。
				isTerminalReady = true
				pendingAutoFocus = true
				// 初期 font size を AppConfig から反映 + 以降の変更を購読。
				let initialSize = AppConfig.shared.terminalFontSize
				webView?.evaluateJavaScript("window.terminalSetFontSize(\(initialSize))", completionHandler: nil)
				fontSizeCancellable = AppConfig.shared.$terminalFontSize
					.dropFirst()
					.removeDuplicates()
					.sink { [weak self] size in
						self?.webView?.evaluateJavaScript("window.terminalSetFontSize(\(size))", completionHandler: nil)
					}
				// Delayed fit to get correct size after SwiftUI layout settles.
				let initialFitDelay: TimeInterval = 0.15
				DispatchQueue.main.asyncAfter(deadline: .now() + initialFitDelay) { [weak self] in
					guard let self, let webView = self.webView, self.ptyService == nil else { return }
					webView.evaluateJavaScript("window.terminalFit()") { [weak self] result, _ in
						guard let self, self.ptyService == nil else { return }
						if let dict = result as? [String: Any],
						   let cols = dict["cols"] as? Int,
						   let rows = dict["rows"] as? Int {
							self.lastResizeCols = cols
							self.lastResizeRows = rows
							NSLog("[Belve] initial fit pane=%@ cols=%d rows=%d",
								  self.paneId ?? "?", cols, rows)
							self.startPTY(cols: cols, rows: rows)
						}
					}
				}

			case "input":
				if let b64 = body["data"] as? String,
				   let data = Data(base64Encoded: b64) {
					ptyService?.send(data)
				}

			case "resize":
				let cols = body["cols"] as? Int ?? 80
				let rows = body["rows"] as? Int ?? 24
				guard cols != lastResizeCols || rows != lastResizeRows else { break }
				lastResizeCols = cols
				lastResizeRows = rows
				ptyService?.setSize(cols: cols, rows: rows)

			case "bell":
				NSSound.beep()

			case "copy":
				if let text = body["text"] as? String {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case "selection":
				// Store selection for Cmd+C
				if let text = body["text"] as? String {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(text, forType: .string)
				}

			case "paste":
				pasteFromPasteboard()

			case "openPath":
				if let rawPath = body["path"] as? String {
					openPathFromTerminal(rawPath)
				}

			case "openUrl":
				if let urlString = body["url"] as? String,
				   let url = URL(string: urlString) {
					NSWorkspace.shared.open(url)
				}

			case "shortcut":
				if let key = body["key"] as? String {
					handleShortcut(key: key, shift: body["shift"] as? Bool ?? false)
				}

			case "title":
				// Could update tab/pane title
				break

			case "log":
				if let msg = body["msg"] as? String {
					NSLog("[Belve][xterm] \(msg)")
				}

			default:
				break
			}
		}

		private func startPTY(cols: Int, rows: Int) {
			guard let project else { return }
			isWaitingForInitialOutput = project.isRemote

			// Build environment from provider
			var env = project.provider.launcherEnvironment(
				projectId: project.id.uuidString,
				paneId: paneId ?? "",
				paneIndex: paneIndex
			)
			env["BELVE_SESSION"] = "1"
			env["BELVE_COLS"] = "\(cols)"
			env["BELVE_ROWS"] = "\(rows)"
			// belve-persist が parent (= Belve.app) の死活監視に使う。Belve 終了で
			// orphan 化した belve-persist client / daemon が自動 exit する。
			// container broker や mac-master は self-spawn なので env を継承しない。
			env["BELVE_PARENT_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"

			// Add Belve's bin directory to PATH
			if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
				let resourceBin = execDir
					.deletingLastPathComponent()
					.appendingPathComponent("Resources/bin")
				let currentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
				env["PATH"] = "\(resourceBin.path):\(currentPath)"
			}

			// Resolve launcher script path
			let launcherPath = "/tmp/belve-shell/belve-launcher.sh"

			// Phase B: ensure the per-VM router forward is up. Returns the local
			// port that the launcher uses for the broker connection. Mac sends
			// a JSON preamble (with PROJ_SHORT) so the router dispatches to the
			// right container/VM broker. 1 forward per VM, regardless of project.
			if project.isRemote, let host = project.sshHost {
				let pid = project.id
				let isDev = project.isDevContainer
				let workspacePath = project.path ?? ""
				let projShort = String(project.id.uuidString.prefix(8))
				let binDirOpt: String? = {
					if let r = Bundle.main.resourcePath {
						return (r as NSString).appendingPathComponent("bin")
					}
					return nil
				}()
				Task { @MainActor in
					// Phase 2: pane を spawn する前に master に setup を依頼。
					// per-host 直列化 + idempotent なので並列に呼んで OK。
					// 既に setup 済みなら即返却 (= ms 単位)、未だなら走らせて wait。
					if let binDir = binDirOpt {
						do {
							try await MasterClient.shared.ensureSetup(
								projectId: pid,
								host: host,
								isDevContainer: isDev,
								workspacePath: workspacePath,
								projShort: projShort,
								binDir: binDir
							)
						} catch {
							NSLog("[Belve] master.ensureSetup failed: \(error)")
							postConnectionState(isLoading: false)
							postConnectionStatus("Setup failed: \(error.localizedDescription)")
							postDisconnectedState(isDisconnected: true)
							// ProjectStore に分類済み error を渡して overlay 出させる。
							NotificationCenter.default.post(
								name: .belveProjectConnectionError,
								object: nil,
								userInfo: [
									"projectId": pid,
									"host": host,
									"error": error
								]
							)
							return
						}
					}
					do {
						let port = try await SSHTunnelManager.shared.ensureRouterForward(host: host)
						// Phase 4: launcher 廃止。belve-persist を直接 spawn する。
						// `-tcpbackend` モードに attach-or-fork を内蔵化したので、
						// この 1 個の Process が必要なら daemon を fork してから
						// PTY client として attach する。
						guard let belveBin = Self.belvePersistBinaryPath() else {
							NSLog("[Belve] belve-persist binary not found")
							postConnectionState(isLoading: false)
							postConnectionStatus("belve-persist not found")
							postDisconnectedState(isDisconnected: true)
							return
						}
						let sessionName: String
						if paneIndex != 0 {
							sessionName = "belve-\(projShort)-\(paneIndex)"
						} else {
							sessionName = "belve-\(projShort)"
						}
						let sockPath = "/tmp/belve-shell/sessions/\(sessionName).sock"
						try? FileManager.default.createDirectory(
							atPath: "/tmp/belve-shell/sessions",
							withIntermediateDirectories: true
						)
						let args = [
							"-socket", sockPath,
							"-cols", String(cols),
							"-rows", String(rows),
							"-tcpbackend", "127.0.0.1:\(port)",
							"-session", sessionName,
							"-route", projShort,
						]
						spawnPTY(launcherPath: belveBin, args: args, env: env, cols: cols, rows: rows, project: project)
					} catch {
						NSLog("[Belve] router forward failed: \(error)")
						postConnectionState(isLoading: false)
						postConnectionStatus("Tunnel failed: \(error.localizedDescription)")
						postDisconnectedState(isDisconnected: true)
						return
					}
				}
			} else {
				spawnPTY(launcherPath: launcherPath, env: env, cols: cols, rows: rows, project: project)
			}

			// Track active pane on focus
			if let paneId, let paneUUID = UUID(uuidString: paneId) {
				// Set active pane when this terminal gets focus
				DispatchQueue.main.async { [weak self] in
					self?.commandAreaState?.activePaneId = paneUUID
				}
			}
		}

		/// Resolve the path to the bundled `belve-persist-darwin-arm64` binary.
		/// Used to spawn the local PTY client + tcpbackend daemon (Phase 4: replaces
		/// the old bash launcher's path resolution).
		static func belvePersistBinaryPath() -> String? {
			if let resourcePath = Bundle.main.resourcePath {
				let p = (resourcePath as NSString)
					.appendingPathComponent("bin/belve-persist-darwin-arm64")
				if FileManager.default.fileExists(atPath: p) { return p }
			}
			let dev = "/Users/s07309/src/dock-code/Belve.app/Contents/Resources/bin/belve-persist-darwin-arm64"
			if FileManager.default.fileExists(atPath: dev) { return dev }
			return nil
		}

		private func spawnPTY(launcherPath: String, args: [String] = [], env: [String: String], cols: Int, rows: Int, project: Project) {
			do {
				postConnectionState(isLoading: isWaitingForInitialOutput)
				postDisconnectedState(isDisconnected: false)
				let pty = try PTYService.spawn(
					shell: launcherPath,
					args: args,
					environment: env,
					cols: cols,
					rows: rows
				)

				pty.onData = { [weak self] data in
					self?.bufferOutput(data)
				}
				pty.onExit = { [weak self] status in
					self?.handlePTYExit(status: status)
				}

				// Agent notification transport
				if let paneId {
					self.notificationStore?.suppressNotifications(for: paneId, seconds: 3.0)
					pty.agentTransport.onAgentStatus = { [weak self] agentPaneId, sessionId, status, message in
						// Remote (DevContainer / SSH) は BELVE_PANE_ID が shell に
						// 渡らない (= TCP tunnel 経由で env が伝播しない) ため、
						// hook script が paneId="unknown" で OSC を出す。
						// Mac 側で正しい paneId に書き換えて dispatch する。
						let effectivePaneId = (agentPaneId == "unknown") ? paneId : agentPaneId
						self?.notificationStore?.updateAgentStatus(
							paneId: effectivePaneId, sessionId: sessionId, status: status, message: message
						)
					}
				}

				self.ptyService = pty
				NSLog("[Belve] PTY started for project: \(project.name), pane: \(paneId ?? "nil")")
			} catch {
				postConnectionState(isLoading: false)
				postDisconnectedState(isDisconnected: project.isRemote)
				NSLog("[Belve] Failed to start PTY: \(error)")
			}
		}

		/// After PTY resize, hold output until app finishes redrawing
		private var resizeHoldUntil: Date?
		private var resizeStartTime: Date?
		private var resizeFirstDataTime: Date?
		private var resizeLastDataTime: Date?
		private var resizeByteCount: Int = 0
		private var resizeHoldTimer: Timer?

		private var resizeMaxTimer: Timer?

		private func startResizeHold() {
			resizeHoldUntil = Date().addingTimeInterval(3.0)
			resizeStartTime = Date()
			resizeFirstDataTime = nil
			resizeLastDataTime = nil
			resizeByteCount = 0
			// Hard cap: force reveal after 3s even if data keeps flowing
			resizeMaxTimer?.invalidate()
			resizeMaxTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
				guard let self else { return }
				NSLog("[Belve] resize-measure: MAX-TIMEOUT bytes=%d (data still flowing after 3s)", self.resizeByteCount)
				self.resizeHoldUntil = nil
				self.resizeHoldTimer?.invalidate()
				self.resizeHoldTimer = nil
				let b64 = self.outputBuffer.base64EncodedString()
				self.outputBuffer.removeAll(keepingCapacity: true)
				self.webView?.evaluateJavaScript("terminalWrite('\(b64)'); window.terminalSetResizing(false)", completionHandler: nil)
			}
		}

		/// Buffer PTY output and flush every ~4ms to reduce JS calls.
		/// After resize, buffers longer to avoid visible redraw scroll.
		private func bufferOutput(_ data: Data) {
			let parsed = extractBelveStatusMessages(from: statusScanBuffer + data)
			statusScanBuffer = parsed.trailingData

			for statusMessage in parsed.messages {
				handleBelveStatusMessage(statusMessage)
			}

			let cleanData = parsed.outputData
			guard !cleanData.isEmpty else { return }

			if isShowingTransientStatus {
				isShowingTransientStatus = false
				postConnectionState(isLoading: false)
				postConnectionStatus(nil)
			}

			// Clear initial loading state on first real PTY output.
			if isWaitingForInitialOutput {
				isWaitingForInitialOutput = false
				postConnectionState(isLoading: false)
				postConnectionStatus(nil)
			}
			// Focus は構造改善 C で CommandAreaState.activePaneId に集約済み。
			// ここでは触らない。pendingAutoFocus は ready 経路と歩調を合わせるために
			// 保持してるだけで実害なし (= 後段で参照されない)。
			pendingAutoFocus = false
			outputBuffer.append(cleanData)
			if resizeHoldUntil != nil {
				// Measure data arrival
				if resizeFirstDataTime == nil, let start = resizeStartTime {
					resizeFirstDataTime = Date()
					NSLog("[Belve] resize-measure: first-data-latency=%.0fms", Date().timeIntervalSince(start) * 1000)
				}
				if let start = resizeStartTime {
					NSLog("[Belve] resize-chunk: +%dms +%d bytes (total=%d)", Int(Date().timeIntervalSince(start) * 1000), cleanData.count, resizeByteCount + cleanData.count)
				}
				resizeLastDataTime = Date()
				resizeByteCount += cleanData.count
				// During resize hold: reset the quiet timer (data still flowing)
				resizeHoldTimer?.invalidate()
				resizeHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
					guard let self else { return }
					// Print measurements
					if let start = self.resizeStartTime, let first = self.resizeFirstDataTime, let last = self.resizeLastDataTime {
						let firstLatency = first.timeIntervalSince(start) * 1000
						let dataSpan = last.timeIntervalSince(first) * 1000
						let renderStart = Date()
						NSLog("[Belve] resize-measure: first=%.0fms dataSpan=%.0fms bytes=%d", firstLatency, dataSpan, self.resizeByteCount)
						self.resizeHoldUntil = nil
						self.resizeHoldTimer = nil
						let b64 = self.outputBuffer.base64EncodedString()
						self.outputBuffer.removeAll(keepingCapacity: true)
						self.webView?.evaluateJavaScript("terminalWrite('\(b64)'); window.terminalSetResizing(false)") { _, _ in
							NSLog("[Belve] resize-measure: render=%.0fms", Date().timeIntervalSince(renderStart) * 1000)
						}
						return
					}
					self.resizeHoldUntil = nil
					self.resizeHoldTimer = nil
					let b64 = self.outputBuffer.base64EncodedString()
					self.outputBuffer.removeAll(keepingCapacity: true)
					self.webView?.evaluateJavaScript("terminalWrite('\(b64)'); window.terminalSetResizing(false)", completionHandler: nil)
				}
			} else if flushTimer == nil {
				flushTimer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: false) { [weak self] _ in
					self?.flushOutput()
				}
			}
		}

		/// Extract belve-status OSC 9 sequences while preserving normal terminal output.
		private func extractBelveStatusMessages(from data: Data) -> (messages: [String], outputData: Data, trailingData: Data) {
			let prefix = Array("\u{1b}]9;belve-status;".utf8)
			let suffix: UInt8 = 0x07
			let bytes = Array(data)
			var messages: [String] = []
			var output = Data()
			var cursor = 0
			var lastCopied = 0

			while cursor + prefix.count <= bytes.count {
				if Array(bytes[cursor..<(cursor + prefix.count)]) != prefix {
					cursor += 1
					continue
				}

				if lastCopied < cursor {
					output.append(contentsOf: bytes[lastCopied..<cursor])
				}

				var end = cursor + prefix.count
				while end < bytes.count {
					if bytes[end] == suffix {
						let messageBytes = Data(bytes[(cursor + prefix.count)..<end])
						if let message = String(data: messageBytes, encoding: .utf8), !message.isEmpty {
							messages.append(message)
						}
						cursor = end + 1
						lastCopied = cursor
						break
					}
					end += 1
				}

				if end == bytes.count {
					return (messages, output, Data(bytes[cursor...]))
				}
			}

			if lastCopied < bytes.count {
				output.append(contentsOf: bytes[lastCopied...])
			}
			return (messages, output, Data())
		}

		private func handleBelveStatusMessage(_ message: String) {
			isShowingTransientStatus = true
			postDisconnectedState(isDisconnected: false)
			postConnectionState(isLoading: true)
			postConnectionStatus(message)
		}

		private func flushOutput() {
			flushTimer = nil
			guard !outputBuffer.isEmpty else { return }

			// During resize hold: buffer until data stops flowing (200ms quiet)
			if resizeHoldUntil != nil {
				resizeHoldTimer?.invalidate()
				resizeHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
					// No new data for 200ms — redraw is done, flush all at once
					guard let self else { return }
					self.resizeHoldUntil = nil
					self.resizeHoldTimer = nil
					// Flush buffered data first, then reveal the terminal
					let b64 = self.outputBuffer.base64EncodedString()
					self.outputBuffer.removeAll(keepingCapacity: true)
					self.webView?.evaluateJavaScript("terminalWrite('\(b64)'); window.terminalSetResizing(false)", completionHandler: nil)
				}
				return
			}

			let b64 = outputBuffer.base64EncodedString()
			outputBuffer.removeAll(keepingCapacity: true)
			webView?.evaluateJavaScript("terminalWrite('\(b64)')", completionHandler: nil)
		}

		private func focusTerminal() {
			DispatchQueue.main.async { [weak self] in
				self?.webView?.window?.makeFirstResponder(self?.webView)
				self?.webView?.evaluateJavaScript("terminalFocus(true)", completionHandler: nil)
			}
		}

		/// アクティブな key window の first responder が既に terminal WebView なら true。
		/// 接続後 auto-focus が「ユーザーが既に選んでる pane」を奪うのを防ぐ判定に使う。
		static func someTerminalAlreadyFocused() -> Bool {
			guard let fr = NSApp.keyWindow?.firstResponder as? NSView else { return false }
			// TerminalWebView 自身、もしくはその子孫なら true。
			return fr is TerminalWebView || fr.enclosingScrollView?.documentView is TerminalWebView ||
				findAncestor(fr, ofType: TerminalWebView.self) != nil
		}

		private static func findAncestor<T: NSView>(_ view: NSView, ofType: T.Type) -> T? {
			var v: NSView? = view
			while let cur = v {
				if let match = cur as? T { return match }
				v = cur.superview
			}
			return nil
		}

		func performRefit() {
			webView?.evaluateJavaScript("window.terminalFit()") { [weak self] result, _ in
				guard let self else { return }
				if let dict = result as? [String: Any],
				   let cols = dict["cols"] as? Int,
				   let rows = dict["rows"] as? Int,
				   (cols != self.lastResizeCols || rows != self.lastResizeRows) {
					self.lastResizeCols = cols
					self.lastResizeRows = rows
					NSLog("[Belve] refit pane=%@ cols=%d rows=%d", self.paneId ?? "?", cols, rows)
					self.ptyService?.setSize(cols: cols, rows: rows)
				}
			}
		}

		func activatePane() {
			guard let paneId, let paneUUID = UUID(uuidString: paneId) else { return }
			commandAreaState?.activePaneId = paneUUID
			// Tile mode の単一 global focus も同期 (project mode 中は値は使われない)
			TileFilterState.shared.focusedPaneId = paneId
		}

		private var resizeDebounceWorkItem: DispatchWorkItem?
		private var lastResizeCols = 0
		private var lastResizeRows = 0

		/// Resize terminal using fitAddon.proposeDimensions() for accurate cols/rows.
		/// Debounces to let SwiftUI layout settle before measuring DOM.
		/// Also starts the PTY on the first successful fit (after "ready" + correct frame).
		private var ptyResizeWorkItem: DispatchWorkItem?

		func resizeTerminal(width: CGFloat, height: CGFloat) {
			resizeDebounceWorkItem?.cancel()
			// Fit xterm.js after brief debounce (visual only, no PTY resize yet)
			let fitWorkItem = DispatchWorkItem { [weak self] in
				guard let self, let webView = self.webView else { return }
				guard self.isTerminalReady else { return }
				webView.evaluateJavaScript("window.terminalFit()") { [weak self] result, _ in
					guard let self else { return }
					if let dict = result as? [String: Any],
					   let cols = dict["cols"] as? Int,
					   let rows = dict["rows"] as? Int {
						if let reflowMs = dict["reflowMs"] as? Double, let oldCols = dict["oldCols"] as? Int {
							NSLog("[Belve] reflow-measure: oldCols=%d newCols=%d reflow=%.1fms", oldCols, cols, reflowMs)
						}
						if self.ptyService == nil {
							self.lastResizeCols = cols
							self.lastResizeRows = rows
							NSLog("[Belve] initial fit pane=%@ cols=%d rows=%d",
								  self.paneId ?? "?", cols, rows)
							self.startPTY(cols: cols, rows: rows)
							return
						}
						guard cols != self.lastResizeCols || rows != self.lastResizeRows else { return }
						self.lastResizeCols = cols
						self.lastResizeRows = rows
						// Defer PTY resize (triggers SIGWINCH → app redraw) until drag settles
						self.ptyResizeWorkItem?.cancel()
						let ptyWork = DispatchWorkItem { [weak self] in
							guard let self, let webView = self.webView else { return }
							NSLog("[Belve] pty resize pane=%@ cols=%d rows=%d",
								  self.paneId ?? "?", cols, rows)
							// Hide terminal right before SIGWINCH to prevent visible redraw
							webView.evaluateJavaScript("window.terminalSetResizing(true)", completionHandler: nil)
							self.startResizeHold()
							self.ptyService?.setSize(cols: cols, rows: rows)
							// Failsafe: always reveal after max time, even if no data arrives
							DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
								self?.webView?.evaluateJavaScript("window.terminalSetResizing(false)", completionHandler: nil)
							}
						}
						self.ptyResizeWorkItem = ptyWork
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: ptyWork)
					}
				}
			}
			resizeDebounceWorkItem = fitWorkItem
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: fitWorkItem)
		}

		func copySelectionToPasteboard() {
			webView?.evaluateJavaScript("window.terminalGetSelection ? window.terminalGetSelection() : ''") { result, _ in
				guard let text = result as? String, !text.isEmpty else { return }
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(text, forType: .string)
			}
		}

		func pasteFromPasteboard() {
			let pb = NSPasteboard.general
			// Finder 等でファイルコピーした場合は元パスをそのまま貼る (画像ファイルでも
			// 元パス優先 — 画像 data 経由 temp 保存だと参照を失う)。
			// remote project の場合は Mac path を送っても remote agent は読めないので
			// path だけ insert (= ユーザーが自分で対処)。今後ファイル転送に拡張可能。
			if let paths = readClipboardFilePaths(pb), !paths.isEmpty {
				ptyService?.send(paths.joined(separator: " ") + " ")
				return
			}
			// スクショ等の image data は tmp に保存。remote project ならその先で
			// master 経由で remote に転送して remote path を送る。local は Mac path 送る。
			if let localPath = saveClipboardImageToTemp(pb) {
				if let project, project.isRemote, let host = project.sshHost {
					sendImageToRemote(localPath: localPath, host: host, project: project)
				} else {
					ptyService?.send(localPath + " ")
				}
				return
			}
			guard let text = pb.string(forType: .string) else { return }
			ptyService?.send(text)
		}

		/// remote project 用: master 経由で SSH/DevContainer に画像転送。async なので
		/// Task で投げて完了したら remote path を入力。失敗時はエラー path を入れない
		/// (silent fallback 禁止 — ユーザーには NSLog で原因が見える)。
		private func sendImageToRemote(localPath: String, host: String, project: Project) {
			let isDC = project.isDevContainer
			let projShort = String(project.id.uuidString.prefix(8))
			Task { [weak self] in
				do {
					let remotePath = try await MasterClient.shared.transferImage(
						host: host,
						isDevContainer: isDC,
						projShort: projShort,
						localPath: localPath
					)
					await MainActor.run {
						self?.ptyService?.send(remotePath + " ")
					}
				} catch {
					NSLog("[Belve] transferImage failed: \(error.localizedDescription)")
				}
			}
		}

		private func readClipboardFilePaths(_ pb: NSPasteboard) -> [String]? {
			guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] else { return nil }
			let paths = urls.compactMap { $0.isFileURL ? $0.path : nil }
			return paths.isEmpty ? nil : paths
		}

		// クリップボードに画像があれば NSTemporaryDirectory/belve-clipboard/ に保存して
		// path を返す。OS が temp を定期的に掃除するので明示クリーンアップは不要。
		private func saveClipboardImageToTemp(_ pb: NSPasteboard) -> String? {
			let pngData: Data?
			if let png = pb.data(forType: .png) {
				pngData = png
			} else if let tiff = pb.data(forType: .tiff),
					  let rep = NSBitmapImageRep(data: tiff) {
				pngData = rep.representation(using: .png, properties: [:])
			} else {
				return nil
			}
			guard let data = pngData else { return nil }
			let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("belve-clipboard")
			try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
			let ts = Int(Date().timeIntervalSince1970 * 1000)
			let path = (dir as NSString).appendingPathComponent("img-\(ts).png")
			do {
				try data.write(to: URL(fileURLWithPath: path))
				return path
			} catch {
				NSLog("[Belve] failed to save clipboard image: \(error)")
				return nil
			}
		}

		func sendLineDelete() {
			ptyService?.send(Data([0x15]))
		}

		func setMetaPressed(_ isPressed: Bool) {
			webView?.evaluateJavaScript("window.terminalSetMetaPressed?.(\(isPressed ? "true" : "false"))", completionHandler: nil)
		}

		private func openPathFromTerminal(_ rawPath: String) {
			guard let project else { return }
			let parts = splitPathAndLocation(rawPath)
			let resolved = resolveTerminalPath(parts.path, in: project)
			guard let resolved else { return }

			// Check if it's a directory — reveal in file tree instead of opening as file
			let isDir = project.provider.run("test -d \(shellQuote(resolved)) && echo yes || echo no")?.trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
			if isDir {
				NotificationCenter.default.post(
					name: .belveRevealFileInTree,
					object: nil,
					userInfo: ["projectId": project.id, "path": resolved]
				)
				return
			}

			NotificationCenter.default.post(
				name: .belveOpenFileFromTerminal,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"path": resolved,
					"line": parts.line as Any,
					"column": parts.column as Any
				]
			)
		}

		private func shellQuote(_ s: String) -> String {
			"'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
		}

		private func resolveTerminalPath(_ rawPath: String, in project: Project) -> String? {
			let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'`()[]{}<>"))
			guard !trimmed.isEmpty else { return nil }

			let parts = splitPathAndLocation(trimmed)
			let candidate = parts.path
			let provider = project.provider
			let basePath = project.effectivePath

			let candidates: [String]
			if candidate.hasPrefix("/") {
				candidates = [candidate]
			} else if candidate.hasPrefix("./") || candidate.hasPrefix("../") {
				candidates = [
					(basePath as NSString).appendingPathComponent(candidate)
				]
			} else {
				candidates = [
					(basePath as NSString).appendingPathComponent(candidate),
					candidate
				]
			}

			for path in candidates {
				if provider.fileExists(path) {
					return path
				}
				// Also check directories (fileExists only checks files)
				let isDirCheck = provider.run("test -d \(shellQuote(path)) && echo yes || echo no")?.trimmingCharacters(in: .whitespacesAndNewlines)
				if isDirCheck == "yes" {
					return path
				}
			}
			return nil
		}

		private func splitPathAndLocation(_ rawPath: String) -> (path: String, line: Int?, column: Int?) {
			let parts = rawPath.split(separator: ":").map(String.init)
			guard parts.count >= 2 else { return (rawPath, nil, nil) }

			if parts.count >= 3,
			   let line = Int(parts[parts.count - 2]),
			   let column = Int(parts[parts.count - 1]) {
				let path = parts.dropLast(2).joined(separator: ":")
				return (path, line, column)
			}

			if let last = parts.last, let line = Int(last) {
				let path = parts.dropLast().joined(separator: ":")
				return (path, line, nil)
			}

			return (rawPath, nil, nil)
		}

		private func postConnectionState(isLoading: Bool) {
			guard let project, let paneId else { return }
			NotificationCenter.default.post(
				name: .belveTerminalConnectionState,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"isLoading": isLoading
				]
			)
		}

		private func postConnectionStatus(_ message: String?) {
			guard let project, let paneId else { return }
			NotificationCenter.default.post(
				name: .belveTerminalConnectionStatus,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"message": message as Any
				]
			)
		}

		private func postDisconnectedState(isDisconnected: Bool) {
			guard let project, let paneId else { return }
			NotificationCenter.default.post(
				name: .belveTerminalDisconnected,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"isDisconnected": isDisconnected
				]
			)
		}

		private var ptyRetryCount = 0
		/// Retry の最大回数。Remote/Local 共通。Master が落ちて per-host port forward
		/// が再確立するまで数十秒かかる場合があるので、十分な回数を確保しておく。
		/// Backoff 入りなので合計 ~5 分くらいまで粘る。
		private static let ptyMaxRetries = 12

		private func handlePTYExit(status: Int32) {
			postConnectionState(isLoading: false)
			guard let project else { return }
			// Skip if our webView is no longer in the view hierarchy (stale coordinator from reload)
			guard webView?.window != nil else { return }
			NSLog(
				"[Belve] PTY exited for project=%@ pane=%@ status=%d retryCount=%d",
				project.name,
				paneId ?? "nil",
				status,
				ptyRetryCount
			)

			// Local / Remote 共通で auto-retry。Local も killOrphanClients
			// (= app 再起動時の cleanup) で SIGTERM を受けて exit するため retry が必要。
			// Backoff: 2,4,8,16,30,30,30,... (cap=30s)。
			if ptyRetryCount < Self.ptyMaxRetries {
				ptyRetryCount += 1
				ptyService = nil
				let delay = min(30.0, pow(2.0, Double(ptyRetryCount)))
				NSLog("[Belve] Auto-retrying PTY for project=%@ (attempt %d/%d, delay %.0fs)",
					project.name, ptyRetryCount, Self.ptyMaxRetries, delay)
				postReconnectingState(attempt: ptyRetryCount, max: Self.ptyMaxRetries)
				DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
					guard let self else { return }
					let cols = self.lastResizeCols > 0 ? self.lastResizeCols : 80
					let rows = self.lastResizeRows > 0 ? self.lastResizeRows : 24
					self.startPTY(cols: cols, rows: rows)
				}
				return
			}
			postDisconnectedState(isDisconnected: true)
		}

		/// Reconnect 中の状態をターミナル上に視覚表示する用 notification。
		/// Connection status banner (灰色帯) に "Reconnecting…" を出す。
		private func postReconnectingState(attempt: Int, max: Int) {
			guard let project, let paneId else { return }
			let message = "Reconnecting… (\(attempt)/\(max))"
			NotificationCenter.default.post(
				name: .belveTerminalConnectionStatus,
				object: nil,
				userInfo: [
					"projectId": project.id,
					"paneId": paneId,
					"message": message as Any,
				]
			)
		}

		private func handleShortcut(key: String, shift: Bool) {
			switch key {
			case "d":
				if shift {
					commandAreaState?.splitActive(.horizontal)
				} else {
					commandAreaState?.splitActive(.vertical)
				}
			case "w":
				commandAreaState?.closeActivePane()
			case "n":
				NotificationCenter.default.post(name: .belveNewProject, object: nil)
			case "p":
				if shift {
					NotificationCenter.default.post(name: .belveCommandPalette, object: nil)
				}
			case "o":
				NotificationCenter.default.post(name: .belveOpenFolder, object: nil)
			case "s":
				NotificationCenter.default.post(name: .belveFileSave, object: nil)
			case "r":
				NotificationCenter.default.post(name: .belveReloadProject, object: nil)
			case "]":
				NotificationCenter.default.post(name: .belveSelectNextProject, object: nil)
			case "[":
				NotificationCenter.default.post(name: .belveSelectPreviousProject, object: nil)
			case "'":
				NotificationCenter.default.post(name: .belveFocusNextPane, object: nil)
			case ";":
				NotificationCenter.default.post(name: .belveFocusPreviousPane, object: nil)
			case "l":
				NotificationCenter.default.post(name: .belveFocusEditor, object: nil)
			case "\\":
				if !shift {
					NotificationCenter.default.post(name: .belveToggleSidebar, object: nil)
				}
			case "e":
				if shift {
					NotificationCenter.default.post(name: .belveToggleFileTree, object: nil)
				} else {
					NotificationCenter.default.post(name: .belveToggleEditor, object: nil)
				}
			case "z":
				if !shift {
					NotificationCenter.default.post(name: .belveUndo, object: nil)
				}
			case "t":
				if shift {
					// Debug: report dimensions then resize to 40x20
					webView?.evaluateJavaScript("JSON.stringify(window.debugDimensions())") { result, _ in
						NSLog("[Belve] DEBUG dims pane=%@ %@", self.paneId ?? "nil", result as? String ?? "nil")
					}
					NSLog("[Belve] DEBUG: triggering debugResize(40, 20) on pane=%@", paneId ?? "nil")
					webView?.evaluateJavaScript("window.debugResize(40, 20)", completionHandler: nil)
				}
			case ",":
				NotificationCenter.default.post(name: .belveOpenSettings, object: nil)
			default:
				// Forward Cmd+1-9 for project switching
				if let digit = Int(key), digit >= 1 && digit <= 9 {
					NotificationCenter.default.post(name: .belveSwitchProject, object: nil, userInfo: ["index": digit - 1])
				}
			}
		}

		deinit {
			flushTimer?.invalidate()
			if let refitObserver { NotificationCenter.default.removeObserver(refitObserver) }
			postConnectionState(isLoading: false)
			postDisconnectedState(isDisconnected: false)
			ptyService = nil  // PTYService deinit closes fd and kills process
			NSLog("[Belve] Terminal coordinator deinit")
		}
	}
}
