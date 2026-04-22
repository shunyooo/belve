import Foundation

/// Generates the launcher shell script used by PTYService to start shells.
/// Remote connections use SCP to deploy scripts, then simple SSH commands to connect.
/// The script is written to /tmp/belve-shell/belve-launcher.sh and reused.
enum LauncherScriptGenerator {

	/// Ensure the launcher script is generated and up-to-date.
	/// Called once at app startup.
	static func generate() {
		guard let execDir = Bundle.main.executableURL?.deletingLastPathComponent() else { return }

		let belveBin = execDir
			.deletingLastPathComponent()
			.appendingPathComponent("Resources/bin").path
		let embeddedBinDir = findEmbeddedBinDir(execDir: execDir)
		let shell = resolveUserShell()
		let shellName = (shell as NSString).lastPathComponent
		let tmpDir = "/tmp/belve-shell"
		try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

		let launcher = "\(tmpDir)/belve-launcher.sh"
		try? #"""
		#!/bin/bash
		# Local shell launcher. Remote (SSH / DevContainer) panes go through
		# belve-persist directly (XTermTerminalView spawns it with -tcpbackend),
		# so this script only handles the local terminal case.
		export TERM=xterm-256color
		BELVE_BIN_DIR="\#(embeddedBinDir.path)"

		# Local shell setup
		export BELVE_SESSION=1
		export PATH="\#(belveBin):$PATH"
		[ -n "$BELVE_WORKDIR" ] && cd "$BELVE_WORKDIR" 2>/dev/null || true
		PROJ_SHORT=$(echo "${BELVE_PROJECT_ID:-local}" | cut -c1-8)
		if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		    LOCAL_SESSION="belve-${PROJ_SHORT}"
		else
		    LOCAL_SESSION="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		fi
		SHELL_NAME="$(basename "\#(shell)")"

		# Prepare shell-specific rc files
		case "$SHELL_NAME" in
		  bash)
		    cat > "\#(tmpDir)/belve-bashrc" << BASHRC
		[ -f "\$HOME/.bash_profile" ] && source "\$HOME/.bash_profile"
		[ -f "\$HOME/.bashrc" ] && source "\$HOME/.bashrc"
		export PATH="\#(belveBin):\$PATH"
		export BELVE_TTY=\$(tty)
		claude() { "\#(belveBin)/claude" "\$@"; }
		export -f claude
		codex() { "\#(belveBin)/codex" "\$@"; }
		export -f codex
		# Belve: auto-source .env on cd or when .env is edited (unsets prev keys on reload)
		_belve_load_env() {
		    local _m=""
		    [ -f ./.env ] && _m=\$(stat -f %m ./.env 2>/dev/null || stat -c %Y ./.env 2>/dev/null)
		    local _k="\$PWD:\$_m"
		    [ "\$_k" = "\${_BELVE_LAST_ENV_KEY:-}" ] && return
		    _BELVE_LAST_ENV_KEY="\$_k"
		    if [ -n "\${_BELVE_ENV_KEYS:-}" ]; then
		        for _ek in \$_BELVE_ENV_KEYS; do unset "\$_ek"; done
		    fi
		    _BELVE_ENV_KEYS=""
		    if [ -f ./.env ]; then
		        set -a; . ./.env; set +a
		        _BELVE_ENV_KEYS=\$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\\2/p' ./.env | tr '\\n' ' ')
		    fi
		}
		PROMPT_COMMAND="_belve_load_env\${PROMPT_COMMAND:+; \$PROMPT_COMMAND}"
		_belve_load_env
		BASHRC
		    BELVE_SHELL="\#(shell) --rcfile \#(tmpDir)/belve-bashrc -i" ;;
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
		export BELVE_TTY=\$(tty)
		claude() { "\#(belveBin)/claude" "\$@"; }
		codex() { "\#(belveBin)/codex" "\$@"; }
		# Belve: auto-source .env on cd or when .env is edited (unsets prev keys on reload)
		_belve_load_env() {
		    local _m=""
		    [ -f ./.env ] && _m=\$(stat -f %m ./.env 2>/dev/null || stat -c %Y ./.env 2>/dev/null)
		    local _k="\$PWD:\$_m"
		    [ "\$_k" = "\${_BELVE_LAST_ENV_KEY:-}" ] && return
		    _BELVE_LAST_ENV_KEY="\$_k"
		    if [ -n "\${_BELVE_ENV_KEYS:-}" ]; then
		        for _ek in \${=_BELVE_ENV_KEYS}; do unset "\$_ek"; done
		    fi
		    _BELVE_ENV_KEYS=""
		    if [ -f ./.env ]; then
		        set -a; . ./.env; set +a
		        _BELVE_ENV_KEYS=\$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\\2/p' ./.env | tr '\\n' ' ')
		    fi
		}
		autoload -U add-zsh-hook
		add-zsh-hook precmd _belve_load_env
		_belve_load_env
		ZSHRC
		    BELVE_SHELL="ZDOTDIR=\#(tmpDir)/zdotdir \#(shell) -l -i" ;;
		  fish)
		    BELVE_SHELL="\#(shell) --init-command 'set -gx PATH \#(belveBin) \$PATH; function claude; \#(belveBin)/claude \$argv; end; function codex; \#(belveBin)/codex \$argv; end'" ;;
		  *)
		    BELVE_SHELL="\#(shell) -l -i" ;;
		esac

		# Use belve-persist for local session persistence
		PERSIST_BIN="\#(belveBin)/belve-persist-darwin-arm64"
		PERSIST_SOCK="\#(tmpDir)/sessions/${LOCAL_SESSION}.sock"
		mkdir -p "\#(tmpDir)/sessions"

		if [ -x "$PERSIST_BIN" ]; then
		    if [ -S "$PERSIST_SOCK" ]; then
		        "$PERSIST_BIN" -socket "$PERSIST_SOCK" 2>/dev/null && exit 0
		        rm -f "$PERSIST_SOCK"
		    fi
		    # `-cols` / `-rows` を必ず渡す。これが無いと daemon は inner PTY を
		    # default サイズ (0x0 → 80x24 fallback) で作って zsh を起動するため、
		    # 最初の prompt が 80x24 で出力されて scrollback に残る → 後の resize
		    # で claude/codex 等の TUI が崩れた表示になる原因。
		    exec "$PERSIST_BIN" -socket "$PERSIST_SOCK" \
		        -cols "${BELVE_COLS:-80}" -rows "${BELVE_ROWS:-24}" \
		        -command "$BELVE_SHELL"
		fi
		# Fallback: no belve-persist
		exec sh -c "$BELVE_SHELL"
		"""#.write(toFile: launcher, atomically: true, encoding: .utf8)
		try? FileManager.default.setAttributes(
			[.posixPermissions: 0o755], ofItemAtPath: launcher)

		NSLog("[Belve] Launcher script generated (\(shellName)): \(launcher)")
	}

	private static func findEmbeddedBinDir(execDir: URL) -> URL {
		if let resourceURL = Bundle.main.resourceURL {
			let bundleBin = resourceURL.appendingPathComponent("bin")
			if FileManager.default.fileExists(atPath: bundleBin.appendingPathComponent("belve").path) {
				return bundleBin
			}
		}
		let devBin = execDir
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appendingPathComponent("Sources/Belve/Resources/bin")
		return devBin
	}

	/// Resolve user's login shell via Directory Services.
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
		if let shell = output.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
		   !shell.isEmpty {
			return shell
		}
		return "/bin/zsh"
	}
}
