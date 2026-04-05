import GhosttyKit
import Foundation
import AppKit

/// Singleton that owns the Ghostty runtime (ghostty_app_t) and its configuration.
/// Must be initialized once at app launch before any surfaces are created.
final class GhosttyRuntime {
	static let shared = GhosttyRuntime()

	private(set) var app: ghostty_app_t?
	private(set) var config: ghostty_config_t?

	/// Coalesce wakeup -> tick dispatches. The I/O thread may fire wakeup_cb
	/// thousands of times per second during bulk output.
	private var tickScheduled = false
	private let tickLock = NSLock()

	private init() {
		initialize()
	}

	// MARK: - Initialization

	private func initialize() {
		let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
		guard result == GHOSTTY_SUCCESS else {
			NSLog("[Belve] Failed to initialize ghostty: \(result)")
			return
		}

		guard let cfg = ghostty_config_new() else {
			NSLog("[Belve] Failed to create ghostty config")
			return
		}

		ghostty_config_load_default_files(cfg)
		ghostty_config_load_recursive_files(cfg)

		// Launcher script injects Belve env + claude function, then execs user's shell.
		// Ghostty env_vars alone isn't enough because shell rc files (nvm, pyenv)
		// reorder PATH. Shell function (export -f / ZDOTDIR) ensures claude wrapper
		// takes priority regardless of PATH order.
		if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
			let belveBin = execDir
				.deletingLastPathComponent()
				.appendingPathComponent("Resources/bin").path
			let shell = GhosttyRuntime.resolveUserShell()
			let shellName = (shell as NSString).lastPathComponent
			let tmpDir = "/tmp/belve-shell"
			try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

			let launcher = "\(tmpDir)/belve-launcher.sh"
			try? #"""
			#!/bin/sh
			export BELVE_SESSION=1
			export PATH="\#(belveBin):$PATH"
			SHELL_NAME="$(basename "\#(shell)")"
			case "$SHELL_NAME" in
			  bash)
			    claude() { "\#(belveBin)/claude" "$@"; }
			    export -f claude
			    exec \#(shell) -l -i ;;
			  zsh)
			    mkdir -p "\#(tmpDir)/zdotdir"
			    cat > "\#(tmpDir)/zdotdir/.zshenv" << 'ZENV'
			[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv"
			ZENV
			    cat > "\#(tmpDir)/zdotdir/.zprofile" << 'ZPROF'
			[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
			ZPROF
			    cat > "\#(tmpDir)/zdotdir/.zshrc" << ZSHRC
			[ -f "\$HOME/.zshrc" ] && source "\$HOME/.zshrc"
			export PATH="\#(belveBin):\$PATH"
			claude() { "\#(belveBin)/claude" "\$@"; }
			ZSHRC
			    ZDOTDIR="\#(tmpDir)/zdotdir" exec \#(shell) -l -i ;;
			  fish)
			    exec \#(shell) --init-command 'set -gx PATH \#(belveBin) $PATH; function claude; \#(belveBin)/claude $argv; end' ;;
			  *)
			    exec \#(shell) -l -i ;;
			esac
			"""#.write(toFile: launcher, atomically: true, encoding: .utf8)
			try? FileManager.default.setAttributes(
				[.posixPermissions: 0o755], ofItemAtPath: launcher)

			let tmpConf = "\(tmpDir)/ghostty.conf"
			try? "command = \(launcher)\n".write(toFile: tmpConf, atomically: true, encoding: .utf8)
			ghostty_config_load_file(cfg, tmpConf)
			NSLog("[Belve] Ghostty launcher (\(shellName)): \(launcher)")
		}

		ghostty_config_finalize(cfg)

		var runtimeConfig = ghostty_runtime_config_s()
		runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
		runtimeConfig.supports_selection_clipboard = false

		runtimeConfig.wakeup_cb = { _ in
			GhosttyRuntime.shared.scheduleTick()
		}

		runtimeConfig.action_cb = { _, target, action in
			GhosttyRuntime.shared.handleAction(target: target, action: action)
		}

		runtimeConfig.read_clipboard_cb = { userdata, location, state in
			guard let state, let userdata else { return }
			let pasteboard: NSPasteboard = .general
			let text = pasteboard.string(forType: .string) ?? ""
			let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
			if let surface = view.surface {
				text.withCString { ptr in
					ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
				}
			}
		}

		runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
			guard let content, len > 0 else { return }
			let buffer = UnsafeBufferPointer(start: content, count: Int(len))
			for item in buffer {
				guard let dataPtr = item.data else { continue }
				let value = String(cString: dataPtr)
				if let mimePtr = item.mime {
					let mime = String(cString: mimePtr)
					if mime.hasPrefix("text/plain") {
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(value, forType: .string)
						return
					}
				}
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(value, forType: .string)
				return
			}
		}

		runtimeConfig.close_surface_cb = { userdata, _ in
			guard let userdata else { return }
			DispatchQueue.main.async {
				let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
				view.onSurfaceClosed?()
			}
		}

		guard let created = ghostty_app_new(&runtimeConfig, cfg) else {
			NSLog("[Belve] Failed to create ghostty app")
			ghostty_config_free(cfg)
			return
		}

		self.app = created
		self.config = cfg
		NSLog("[Belve] Ghostty runtime initialized")

		// Track app focus
		NotificationCenter.default.addObserver(
			forName: NSApplication.didBecomeActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			if let app = self?.app { ghostty_app_set_focus(app, true) }
		}
		NotificationCenter.default.addObserver(
			forName: NSApplication.didResignActiveNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			if let app = self?.app { ghostty_app_set_focus(app, false) }
		}
	}

	// MARK: - Tick

	func scheduleTick() {
		tickLock.lock()
		defer { tickLock.unlock() }
		guard !tickScheduled else { return }
		tickScheduled = true
		DispatchQueue.main.async { self.tick() }
	}

	private func tick() {
		tickLock.lock()
		tickScheduled = false
		tickLock.unlock()
		guard let app else { return }
		ghostty_app_tick(app)
	}

	// MARK: - Action Handling

	private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
		switch action.tag {
		case GHOSTTY_ACTION_RENDER:
			return true
		case GHOSTTY_ACTION_SET_TITLE:
			return true
		case GHOSTTY_ACTION_MOUSE_SHAPE:
			if let surface = target.target.surface {
				let shape = action.action.mouse_shape
				DispatchQueue.main.async {
					guard let userdata = ghostty_surface_userdata(surface) else { return }
					let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
					view.updateCursorShape(shape)
				}
			}
			return true
		case GHOSTTY_ACTION_RING_BELL:
			NSSound.beep()
			return true
		default:
			return false
		}
	}

	/// Resolve user's login shell via Directory Services (not $SHELL, which may be inherited from parent).
	static func resolveUserShell() -> String {
		let username = NSUserName()
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
		process.arguments = [".", "-read", "/Users/\(username)", "UserShell"]
		let pipe = Pipe()
		process.standardOutput = pipe
		try? process.run()
		process.waitUntilExit()
		let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
		// Output: "UserShell: /bin/zsh"
		if let shell = output.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !shell.isEmpty {
			return shell
		}
		return "/bin/zsh"
	}
}
