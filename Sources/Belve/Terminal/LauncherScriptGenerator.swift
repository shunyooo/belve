import Foundation

/// Generates the launcher shell script used by PTYService to start shells
/// with Belve's PATH injection, SSH/DevContainer configuration, and
/// belve-persist for session persistence (replaces tmux).
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
		let belveScriptData = (try? Data(contentsOf: embeddedBinDir.appendingPathComponent("belve"))) ?? Data()
		let claudeScriptData = (try? Data(contentsOf: embeddedBinDir.appendingPathComponent("claude"))) ?? Data()
		let belveScriptBase64 = belveScriptData.base64EncodedString()
		let claudeScriptBase64 = claudeScriptData.base64EncodedString()
		let persistBinDir = embeddedBinDir.path
		let shell = resolveUserShell()
		let shellName = (shell as NSString).lastPathComponent
		let tmpDir = "/tmp/belve-shell"
		try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

		let launcher = "\(tmpDir)/belve-launcher.sh"
		try? #"""
		#!/bin/bash
		export TERM=xterm-256color
		SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ControlMaster=auto -o ControlPath=/tmp/belve-ssh-%r@%h:%p -o ControlPersist=600"
		BELVE_SCRIPT_B64="\#(belveScriptBase64)"
		CLAUDE_SCRIPT_B64="\#(claudeScriptBase64)"
		PERSIST_BIN_DIR="\#(persistBinDir)"
		REMOTE_LOG_FILE="/tmp/belve-remote-launch.log"

		decode_to_file() {
		    encoded="$1"
		    path="$2"
		    if command -v base64 >/dev/null 2>&1; then
		        if printf '%s' "$encoded" | base64 -d > "$path" 2>/dev/null; then
		            return 0
		        fi
		        if printf '%s' "$encoded" | base64 --decode > "$path" 2>/dev/null; then
		            return 0
		        fi
		    fi
		    if command -v python3 >/dev/null 2>&1; then
		        python3 - "$path" "$encoded" <<'PY'
		import base64
		import pathlib
		import sys
		pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(sys.argv[2]))
		PY
		        return $?
		    fi
		    return 1
		}

		write_remote_belve_files() {
		    mkdir -p "$HOME/.belve/bin" "$HOME/.belve/zdotdir"
		    decode_to_file "$BELVE_SCRIPT_B64" "$HOME/.belve/bin/belve" || exit 1
		    decode_to_file "$CLAUDE_SCRIPT_B64" "$HOME/.belve/bin/claude" || exit 1
		    chmod +x "$HOME/.belve/bin/belve" "$HOME/.belve/bin/claude" 2>/dev/null
		}

		# Upload belve-persist binary via SCP (too large for base64 in shell vars)
		deploy_persist_binary() {
		    local target_host="$1"
		    local target_path="$2"
		    local arch=$(ssh -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5 "$target_host" "uname -m" 2>/dev/null)
		    local src_bin
		    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
		        src_bin="$PERSIST_BIN_DIR/belve-persist-linux-arm64"
		    else
		        src_bin="$PERSIST_BIN_DIR/belve-persist-linux-amd64"
		    fi
		    [ -f "$src_bin" ] || return 1
		    # Only upload if binary differs (check md5)
		    local local_md5=$(md5 -q "$src_bin" 2>/dev/null || md5sum "$src_bin" 2>/dev/null | cut -d' ' -f1)
		    local remote_md5=$(ssh -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5 "$target_host" "md5sum '$target_path' 2>/dev/null | cut -d' ' -f1" 2>/dev/null)
		    if [ "$local_md5" != "$remote_md5" ]; then
		        scp -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10 "$src_bin" "$target_host:$target_path" 2>/dev/null || return 1
		        ssh -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=5 "$target_host" "chmod +x '$target_path'" 2>/dev/null
		    fi
		}

		write_remote_bootstrap() {
		    mkdir -p "$HOME/.belve" "$HOME/.belve/zdotdir"
		    cat > "$HOME/.belve/session-bootstrap.sh" <<BELVE_BOOTSTRAP
		#!/bin/sh
		export BELVE_SESSION=1
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		export PATH="$HOME/.belve/bin:\$PATH"
		SHELL_PATH="\${SHELL:-/bin/bash}"
		SHELL_NAME="\$(basename "\$SHELL_PATH")"
		case "\$SHELL_NAME" in
		  bash)
		    cat > "$HOME/.belve/belve-bashrc" <<'BASHRC'
		[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
		[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
		export PATH="$HOME/.belve/bin:$PATH"
		BASHRC
		    exec "\$SHELL_PATH" --rcfile "$HOME/.belve/belve-bashrc" -i ;;
		  zsh)
		    cat > "$HOME/.belve/zdotdir/.zshenv" <<'ZENV'
		[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv"
		ZENV
		    cat > "$HOME/.belve/zdotdir/.zprofile" <<'ZPROF'
		[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
		ZPROF
		    cat > "$HOME/.belve/zdotdir/.zshrc" <<'ZSHRC'
		[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
		export PATH="$HOME/.belve/bin:$PATH"
		ZSHRC
		    exec env ZDOTDIR="$HOME/.belve/zdotdir" "\$SHELL_PATH" -l -i ;;
		  fish)
		    exec "\$SHELL_PATH" --init-command 'set -gx PATH "$HOME/.belve/bin" \$PATH' ;;
		  *)
		    exec env PATH="$HOME/.belve/bin:$PATH" "\$SHELL_PATH" -l -i ;;
		esac
		BELVE_BOOTSTRAP
		    chmod +x "$HOME/.belve/session-bootstrap.sh"
		}

		# Start or attach to a belve-persist session.
		# belve-persist replaces tmux: pure PTY passthrough, no mouse/OSC interference.
		belve_persist_session() {
		    local session_name="$1"
		    local work_dir="$2"
		    local sock="$HOME/.belve/sessions/${session_name}.sock"
		    mkdir -p "$HOME/.belve/sessions"

		    if [ -n "$work_dir" ]; then
		        cd "$work_dir" 2>/dev/null || true
		    fi

		    # Check if existing session is alive by testing socket connectivity
		    if [ -S "$sock" ]; then
		        # Quick test: can we connect? If daemon is dead, connect fails instantly
		        if python3 -c "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);s.close()" "$sock" 2>/dev/null || \
		           perl -e 'use IO::Socket::UNIX;IO::Socket::UNIX->new(Peer=>$ARGV[0]) or exit 1' "$sock" 2>/dev/null; then
		            exec "$HOME/.belve/bin/belve-persist" -socket "$sock"
		        fi
		        # Stale socket — remove
		        rm -f "$sock"
		    fi

		    # Create new session with correct initial size
		    exec "$HOME/.belve/bin/belve-persist" -socket "$sock" -cols "${BELVE_COLS:-80}" -rows "${BELVE_ROWS:-24}" -command "$HOME/.belve/session-bootstrap.sh"
		}

		begin_remote_log() {
		    : "${REMOTE_LOG_FILE:=/tmp/belve-remote-launch.log}"
		    if [ -w /tmp ] || [ ! -e "$REMOTE_LOG_FILE" ]; then
		        exec 2>> "$REMOTE_LOG_FILE"
		        echo "===== $(date '+%Y-%m-%d %H:%M:%S') remote launch =====" >&2
		    fi
		    set -x
		}

		# SSH/DevContainer: connect with belve-persist for session persistence
		# belve-persist is a transparent PTY proxy: no mouse interference, full OSC passthrough
		# Session naming: belve-{PROJECT_ID_short} for primary, belve-{PROJECT_ID_short}-{N} for splits
		if [ -n "$BELVE_SSH_HOST" ]; then
		    PROJ_SHORT=$(echo "$BELVE_PROJECT_ID" | cut -c1-8)
		    if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		        SESSION_NAME="belve-${PROJ_SHORT}"
		    else
		        SESSION_NAME="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		    fi

		    # Deploy belve-persist binary to SSH host first
		    deploy_persist_binary "$BELVE_SSH_HOST" "/tmp/belve-persist-binary"

		    if [ -n "$BELVE_DEVCONTAINER" ] && [ -n "$BELVE_REMOTE_PATH" ]; then
		        # DevContainer: belve-persist runs on HOST, spawns docker exec as child.
		        # This avoids Docker's process lifecycle issues (docker exec kills processes on disconnect).
		        # Upload setup + persist script to host
		        SSH_SCRIPT="/tmp/belve-ssh-${BELVE_PANE_INDEX:-0}.sh"
		        /usr/bin/ssh -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$BELVE_SSH_HOST" "cat > $SSH_SCRIPT && chmod +x $SSH_SCRIPT" <<BELVE_DC
		#!/bin/bash
		export TERM=xterm-256color
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		export BELVE_COLS='${BELVE_COLS:-80}'
		export BELVE_ROWS='${BELVE_ROWS:-24}'
		BELVE_SCRIPT_B64="$BELVE_SCRIPT_B64"
		CLAUDE_SCRIPT_B64="$CLAUDE_SCRIPT_B64"
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		$(typeset -f belve_persist_session)

		# Setup: deploy scripts into container
		REMOTE_PATH="$BELVE_REMOTE_PATH"
		if [ "\${REMOTE_PATH:0:2}" = "~/" ]; then
		    REMOTE_PATH="\$HOME/\${REMOTE_PATH:2}"
		fi
		cd "\$REMOTE_PATH" 2>/dev/null || cd "\$HOME" || true
		INFO=\$(devcontainer up --workspace-folder . --log-format json 2>/dev/null | tail -1)
		CID=\$(printf '%s' "\$INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("containerId",""))')
		RWS=\$(printf '%s' "\$INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("remoteWorkspaceFolder",""))')
		[ -n "\$CID" ] || { echo "devcontainer up failed"; exit 1; }

		# Deploy belve/claude scripts into container
		docker exec "\$CID" mkdir -p /root/.belve/bin /root/.belve/sessions 2>/dev/null
		docker exec -i "\$CID" bash <<'SETUP_INNER'
		export BELVE_SCRIPT_B64='$BELVE_SCRIPT_B64'
		export CLAUDE_SCRIPT_B64='$CLAUDE_SCRIPT_B64'
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		write_remote_belve_files
		write_remote_bootstrap
		SETUP_INNER

		# belve-persist on HOST manages docker exec as child
		cp /tmp/belve-persist-binary "\$HOME/.belve/bin/belve-persist" 2>/dev/null
		chmod +x "\$HOME/.belve/bin/belve-persist" 2>/dev/null
		mkdir -p "\$HOME/.belve/sessions"

		PERSIST_SOCK="\$HOME/.belve/sessions/$SESSION_NAME.sock"

		# Attach if session is alive, otherwise create new
		if [ -S "\$PERSIST_SOCK" ]; then
		    # Test if daemon is still running
		    if "\$HOME/.belve/bin/belve-persist" -socket "\$PERSIST_SOCK" 2>/dev/null; then
		        exit 0
		    fi
		    rm -f "\$PERSIST_SOCK"
		fi
		exec "\$HOME/.belve/bin/belve-persist" -socket "\$PERSIST_SOCK" -cols "${BELVE_COLS:-80}" -rows "${BELVE_ROWS:-24}" -command docker exec -it -w "\$RWS" -e BELVE_SESSION=1 -e BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}' -e BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}' -e BELVE_PANE_ID='${BELVE_PANE_ID:-}' -e TERM=xterm-256color "\$CID" /root/.belve/session-bootstrap.sh
		BELVE_DC
		        [ $? -eq 0 ] || { echo "DevContainer setup failed"; exit 1; }
		        DC_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ConnectTimeout=10"
		        /usr/bin/ssh $DC_SSH_OPTS -tt "$BELVE_SSH_HOST" "exec $SSH_SCRIPT"
		    else
		        # SSH: upload script with belve-persist integration, then execute
		        SSH_SCRIPT="/tmp/belve-ssh-${BELVE_PANE_INDEX:-0}.sh"
		        /usr/bin/ssh -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$BELVE_SSH_HOST" "cat > $SSH_SCRIPT && chmod +x $SSH_SCRIPT" <<BELVE_REMOTE
		#!/bin/bash
		export TERM=xterm-256color
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		export BELVE_COLS='${BELVE_COLS:-80}'
		export BELVE_ROWS='${BELVE_ROWS:-24}'
		BELVE_SCRIPT_B64="$BELVE_SCRIPT_B64"
		CLAUDE_SCRIPT_B64="$CLAUDE_SCRIPT_B64"
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		$(typeset -f belve_persist_session)
		write_remote_belve_files
		write_remote_bootstrap
		# belve-persist binary is deployed via SCP to ~/.belve/bin/
		cp /tmp/belve-persist-binary "\$HOME/.belve/bin/belve-persist" 2>/dev/null
		chmod +x "\$HOME/.belve/bin/belve-persist" 2>/dev/null
		SESSION_NAME="$SESSION_NAME"
		WORK_DIR="$BELVE_REMOTE_PATH"
		[ -n "\$WORK_DIR" ] && cd "\$WORK_DIR" 2>/dev/null
		belve_persist_session "\$SESSION_NAME" "\$WORK_DIR"
		BELVE_REMOTE
		        [ $? -eq 0 ] || { echo "SSH setup failed"; exit 1; }
		        DC_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ConnectTimeout=10"
		        /usr/bin/ssh $DC_SSH_OPTS -tt "$BELVE_SSH_HOST" "exec $SSH_SCRIPT"
		    fi
		    echo ""
		    echo "🔌 SSH disconnected."
		    echo "Reconnect from Belve when you're ready."
		    exit 0
		fi
		# Local shell setup
		export BELVE_SESSION=1
		export PATH="\#(belveBin):$PATH"
		PROJ_SHORT=$(echo "${BELVE_PROJECT_ID:-local}" | cut -c1-8)
		if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		    TMUX_SESSION="belve-${PROJ_SHORT}"
		else
		    TMUX_SESSION="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		fi
		SHELL_NAME="$(basename "\#(shell)")"

		# Prepare shell-specific rc files
		case "$SHELL_NAME" in
		  bash)
		    cat > "\#(tmpDir)/belve-bashrc" << BASHRC
		[ -f "\$HOME/.bash_profile" ] && source "\$HOME/.bash_profile"
		[ -f "\$HOME/.bashrc" ] && source "\$HOME/.bashrc"
		export PATH="\#(belveBin):\$PATH"
		claude() { "\#(belveBin)/claude" "\$@"; }
		export -f claude
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
		claude() { "\#(belveBin)/claude" "\$@"; }
		ZSHRC
		    BELVE_SHELL="ZDOTDIR=\#(tmpDir)/zdotdir \#(shell) -l -i" ;;
		  fish)
		    BELVE_SHELL="\#(shell) --init-command 'set -gx PATH \#(belveBin) \$PATH; function claude; \#(belveBin)/claude \$argv; end'" ;;
		  *)
		    BELVE_SHELL="\#(shell) -l -i" ;;
		esac

		# Use belve-persist for local session persistence
		PERSIST_BIN="\#(belveBin)/belve-persist-darwin-arm64"
		if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		    LOCAL_SESSION="belve-${PROJ_SHORT}"
		else
		    LOCAL_SESSION="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		fi
		PERSIST_SOCK="\#(tmpDir)/sessions/${LOCAL_SESSION}.sock"
		mkdir -p "\#(tmpDir)/sessions"

		if [ -x "$PERSIST_BIN" ]; then
		    # Attach if session exists, otherwise create
		    if [ -S "$PERSIST_SOCK" ]; then
		        exec "$PERSIST_BIN" -socket "$PERSIST_SOCK"
		    fi
		    rm -f "$PERSIST_SOCK"
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
