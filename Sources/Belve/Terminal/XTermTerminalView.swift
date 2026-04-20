import SwiftUI
import WebKit

final class TerminalWebView: WKWebView {
	var onCopyCommand: (() -> Void)?
	var onPasteCommand: (() -> Void)?
	var onLineDeleteCommand: (() -> Void)?
	var onMetaKeyChanged: ((Bool) -> Void)?
	var onMouseFocus: (() -> Void)?

	override var acceptsFirstResponder: Bool { true }

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
	@EnvironmentObject var notificationStore: NotificationStore
	@EnvironmentObject var commandAreaState: CommandAreaState

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.userContentController.add(context.coordinator, name: "terminalHandler")

		let initialFrame = NSRect(x: 0, y: 0, width: max(1, viewWidth), height: max(1, viewHeight))
		let webView = TerminalWebView(frame: initialFrame, configuration: config)
		webView.autoresizingMask = [.width, .height]
		let terminalIdentifier = paneId.map { "BelveTerminalWebView:\($0)" } ?? "BelveTerminalWebView"
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
		context.coordinator.webView = webView
		context.coordinator.project = project
		context.coordinator.paneId = paneId
		context.coordinator.paneIndex = paneIndex
		context.coordinator.notificationStore = notificationStore
		context.coordinator.commandAreaState = commandAreaState

		if let html = Self.buildHTML() {
			webView.loadHTMLString(html, baseURL: nil)
		}

		// Register pane → project mapping for agent notifications
		if let paneId {
			notificationStore.registerPane(paneId: paneId, projectId: project.id)
		}

		// Listen for project switch refit notifications
		context.coordinator.refitObserver = NotificationCenter.default.addObserver(
			forName: .belveTerminalRefit, object: nil, queue: .main
		) { [weak coordinator = context.coordinator] notif in
			guard let coordinator,
				  let projectId = notif.userInfo?["projectId"] as? UUID,
				  coordinator.project?.id == projectId else { return }
			coordinator.performRefit()
		}

		return webView
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		if viewWidth > 0, viewHeight > 0 {
			let newFrame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
			if nsView.frame.size != newFrame.size {
				NSLog("[Belve] updateNSView pane=%@ viewW=%.0f viewH=%.0f oldW=%.0f oldH=%.0f",
					  paneId ?? "?", viewWidth, viewHeight, nsView.frame.width, nsView.frame.height)
				nsView.frame = newFrame
			}
			context.coordinator.resizeTerminal(width: viewWidth, height: viewHeight)
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

		/// Buffer PTY output and flush on a timer to avoid excessive JS calls
		private var outputBuffer = Data()
		private var statusScanBuffer = Data()
		private var flushTimer: Timer?
		private var isWaitingForInitialOutput = false
		private var isTerminalReady = false
		private var isShowingTransientStatus = false

		func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
			guard let body = message.body as? [String: Any],
				  let type = body["type"] as? String else { return }

			switch type {
			case "ready":
				// Set flag and trigger fit after a short delay to ensure
				// updateNSView has set the correct WKWebView frame.
				isTerminalReady = true
				focusTerminal()
				// Delayed fit to get correct size after SwiftUI layout settles
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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

			// Remote projects: reserve a local port; the launcher establishes the actual
			// `ssh -O forward` after deploy+setup populate ~/.belve/projects/<short>.env.
			if project.isRemote, let host = project.sshHost {
				do {
					let port = try SSHTunnelManager.shared.reservePort(host: host, projectId: project.id)
					env["BELVE_LOCAL_BROKER_PORT"] = String(port)
				} catch {
					NSLog("[Belve] port reservation failed: \(error)")
					postConnectionState(isLoading: false)
					postConnectionStatus("Tunnel failed: \(error.localizedDescription)")
					postDisconnectedState(isDisconnected: true)
					return
				}
			}
			spawnPTY(launcherPath: launcherPath, env: env, cols: cols, rows: rows, project: project)

			// Track active pane on focus
			if let paneId, let paneUUID = UUID(uuidString: paneId) {
				// Set active pane when this terminal gets focus
				DispatchQueue.main.async { [weak self] in
					self?.commandAreaState?.activePaneId = paneUUID
				}
			}
		}

		private func spawnPTY(launcherPath: String, env: [String: String], cols: Int, rows: Int, project: Project) {
			do {
				postConnectionState(isLoading: isWaitingForInitialOutput)
				postDisconnectedState(isDisconnected: false)
				let pty = try PTYService.spawn(
					shell: launcherPath,
					args: [],
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
				if paneId != nil {
					pty.agentTransport.onAgentStatus = { [weak self] agentPaneId, status, message in
						self?.notificationStore?.updateAgentStatus(
							paneId: agentPaneId, status: status, message: message
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
			guard let text = NSPasteboard.general.string(forType: .string) else { return }
			ptyService?.send(text)
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

			if project.isRemote {
				// Auto-retry up to 3 times for remote projects (initial deploy/setup can take time)
				if ptyRetryCount < 3 {
					ptyRetryCount += 1
					ptyService = nil
					let delay = Double(ptyRetryCount) * 2.0 // 2s, 4s, 6s
					NSLog("[Belve] Auto-retrying PTY for project=%@ (attempt %d, delay %.0fs)", project.name, ptyRetryCount, delay)
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
				if shift {
					NotificationCenter.default.post(name: .belveToggleSessionBar, object: nil)
				} else {
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
