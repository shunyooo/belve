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
		export TERM=xterm-256color
		BELVE_BIN_DIR="\#(embeddedBinDir.path)"

		# Remote (SSH / DevContainer): Phase 2 移行で deploy_bundle / belve-setup の
		# 呼び出しは Mac master daemon (`belve-persist -mac-master`) が担当する
		# ようになり、launcher は belve-persist client での attach だけ行う。
		# Mac 側 (XTermTerminalView.startPTY) で master.ensureSetup を await して
		# から PTY を spawn しているので、ここに辿り着いた時点で setup は完了済み。
		if [ -n "$BELVE_SSH_HOST" ]; then
		    PROJ_SHORT=$(echo "$BELVE_PROJECT_ID" | cut -c1-8)
		    if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		        SESSION_NAME="belve-${PROJ_SHORT}"
		    else
		        SESSION_NAME="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		    fi

		    # Status reporting for loading UI
		    belve_status() { printf '\x1b]9;belve-status;%s\x07' "$1"; }

		    if [ -z "${BELVE_LOCAL_BROKER_PORT:-}" ]; then
		        belve_status "Router port not set"
		        echo "[belve] ERROR: BELVE_LOCAL_BROKER_PORT not set (Swift side should have set it)" >&2
		        exit 1
		    fi

		    belve_status "Attaching session..."
		    PERSIST_BIN="$BELVE_BIN_DIR/belve-persist-darwin-arm64"
		    PERSIST_SOCK="\#(tmpDir)/sessions/${SESSION_NAME}.sock"
		    VERFILE="\#(tmpDir)/sessions/${SESSION_NAME}.ver"
		    mkdir -p "\#(tmpDir)/sessions"

		    # Version check: kill stale master if binary was updated
		    CURRENT_VER=$(md5 -q "$PERSIST_BIN" 2>/dev/null || md5sum "$PERSIST_BIN" 2>/dev/null | cut -d' ' -f1)
		    if [ -S "$PERSIST_SOCK" ] && [ -f "$VERFILE" ]; then
		        OLD_VER=$(cat "$VERFILE" 2>/dev/null)
		        if [ "$CURRENT_VER" != "$OLD_VER" ]; then
		            pkill -f "belve-persist.*$PERSIST_SOCK" 2>/dev/null || true
		            rm -f "$PERSIST_SOCK" "$VERFILE"
		        fi
		    fi

		    # Attach to existing local master if present, else start one, then attach as client.
		    # tcpbackend mode is daemon-only; the SAME launcher process has to also be the PTY
		    # client (via a second `-socket`-only invocation that calls tryAttach).
		    if [ -S "$PERSIST_SOCK" ]; then
		        "$PERSIST_BIN" -socket "$PERSIST_SOCK" && exit 0
		        rm -f "$PERSIST_SOCK"
		    fi
		    echo "$CURRENT_VER" > "$VERFILE"

		    # 1) Start tcpbackend daemon in the background (detached, no tty).
		    #    -route X: send {"projShort":"X","kind":"pty"} preamble to the
		    #    router so it can dispatch to the right container broker.
		    nohup "$PERSIST_BIN" -socket "$PERSIST_SOCK" \
		        -cols "${BELVE_COLS:-80}" -rows "${BELVE_ROWS:-24}" \
		        -tcpbackend "127.0.0.1:$BELVE_LOCAL_BROKER_PORT" \
		        -session "$SESSION_NAME" \
		        -route "$PROJ_SHORT" >/dev/null 2>&1 &
		    disown 2>/dev/null || true

		    # 2) Wait for socket to appear, then attach as client (exec replaces this shell)
		    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		        [ -S "$PERSIST_SOCK" ] && break
		        sleep 0.1
		    done
		    exec "$PERSIST_BIN" -socket "$PERSIST_SOCK"
		fi

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
		    exec "$PERSIST_BIN" -socket "$PERSIST_SOCK" -command "$BELVE_SHELL"
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
