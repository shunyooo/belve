import Foundation

/// Generates the launcher shell script used by PTYService to start shells
/// with Belve's PATH injection, SSH/DevContainer/tmux configuration.
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
		    chmod +x "$HOME/.belve/bin/belve" "$HOME/.belve/bin/claude"
		}

		write_remote_bootstrap() {
		    mkdir -p "$HOME/.belve" "$HOME/.belve/zdotdir"
		    cat > "$HOME/.belve/session-bootstrap.sh" <<EOF
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
		EOF
		    chmod +x "$HOME/.belve/session-bootstrap.sh"
		}

		belve_tmux() {
		    command tmux -f /dev/null -L belve "$@"
		}

		prepare_belve_tmux_session() {
		    session_name="$1"
		    belve_tmux has-session -t "$session_name" 2>/dev/null || return 0
		    # Kill stale clients whose PTY is dead, then detach any remaining
		    belve_tmux list-clients -t "$session_name" -F '#{client_tty}' 2>/dev/null | while IFS= read -r client_tty; do
		        [ -n "$client_tty" ] || continue
		        if [ ! -e "$client_tty" ]; then
		            # PTY is dead — force kill via tmux server
		            belve_tmux kill-session -t "$session_name" 2>/dev/null || true
		            return 0
		        fi
		        belve_tmux detach-client -t "$client_tty" 2>/dev/null || true
		    done
		}

		write_devcontainer_entrypoint() {
		    entrypoint_path="$1"
		    cat > "$entrypoint_path" <<EOF
		#!/bin/bash
		export TERM=xterm-256color
		export BELVE_SESSION=1
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		TMUX_SESSION="$TMUX_SESSION"
		BELVE_SCRIPT_B64="$BELVE_SCRIPT_B64"
		CLAUDE_SCRIPT_B64="$CLAUDE_SCRIPT_B64"
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		$(typeset -f belve_tmux)
		$(typeset -f prepare_belve_tmux_session)
		write_remote_belve_files
		write_remote_bootstrap
		if command -v tmux >/dev/null 2>&1; then
		    belve_tmux start-server 2>/dev/null || true
		    belve_tmux set -s default-terminal xterm-256color 2>/dev/null
		    # Clean stale clients first, then create/attach
		    prepare_belve_tmux_session "$TMUX_SESSION"
		    belve_tmux has-session -t "$TMUX_SESSION" 2>/dev/null || belve_tmux new-session -d -s "$TMUX_SESSION" "\$HOME/.belve/session-bootstrap.sh"
		    belve_tmux set -t "$TMUX_SESSION" status off 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" prefix None 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" mouse on 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" escape-time 0 2>/dev/null
		    belve_tmux setw -t "$TMUX_SESSION" pane-border-status off 2>/dev/null
		    belve_tmux bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    belve_tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    exec tmux -f /dev/null -L belve attach-session -d -t "$TMUX_SESSION"
		fi
		exec "\$HOME/.belve/session-bootstrap.sh"
		EOF
		    chmod +x "$entrypoint_path"
		}

		begin_remote_log() {
		    : "${REMOTE_LOG_FILE:=/tmp/belve-remote-launch.log}"
		    if [ -w /tmp ] || [ ! -e "$REMOTE_LOG_FILE" ]; then
		        exec 2>> "$REMOTE_LOG_FILE"
		        echo "===== $(date '+%Y-%m-%d %H:%M:%S') remote launch =====" >&2
		    fi
		    set -x
		}

		# SSH/DevContainer: connect with tmux for session persistence
		# tmux is transparent: no status bar, no prefix key, no keybinds — pure session persistence
		# Session naming: belve-{PROJECT_ID_short} for primary, belve-{PROJECT_ID_short}-{N} for splits
		if [ -n "$BELVE_SSH_HOST" ]; then
		    PROJ_SHORT=$(echo "$BELVE_PROJECT_ID" | cut -c1-8)
		    if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		        TMUX_SESSION="belve-${PROJ_SHORT}"
		    else
		        TMUX_SESSION="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		    fi
		    # tmux transparent mode: session-local settings (no UI, no prefix)
		    # Use tmux mouse + copy-mode for selection/scroll, and forward clipboard via OSC52.
		    TMUX_APPLY="tmux set -t $TMUX_SESSION status off; tmux set -t $TMUX_SESSION prefix None; tmux set -t $TMUX_SESSION mouse on; tmux set -t $TMUX_SESSION escape-time 0; tmux setw -t $TMUX_SESSION pane-border-status off; tmux set -g default-terminal xterm-256color"

		    if [ -n "$BELVE_DEVCONTAINER" ] && [ -n "$BELVE_REMOTE_PATH" ]; then
		        # Single SSH command — no ControlMaster (avoids being killed when old PTY's master dies)
		        DC_SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ConnectTimeout=10"
		        /usr/bin/ssh $DC_SSH_OPTS -tt "$BELVE_SSH_HOST" "export TERM=xterm-256color; cd $BELVE_REMOTE_PATH && INFO=\$(devcontainer up --workspace-folder . --log-format json 2>/dev/null | tail -1) && CID=\$(printf '%s' \"\$INFO\" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(\"containerId\",\"\"))') && RWS=\$(printf '%s' \"\$INFO\" | python3 -c 'import json,sys;print(json.load(sys.stdin).get(\"remoteWorkspaceFolder\",\"\"))') && exec docker exec -it -w \"\$RWS\" \"\$CID\" /bin/bash -c 'command -v tmux >/dev/null && { tmux -f /dev/null -L belve bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null; tmux -f /dev/null -L belve bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null; }; exec /bin/bash ./.belve-devcontainer-entry-${BELVE_PANE_INDEX:-0}.sh'"
		    elif [ -n "$BELVE_REMOTE_PATH" ]; then
		        /usr/bin/ssh $SSH_OPTS -tt "$BELVE_SSH_HOST" /bin/bash <<EOF
		stty -echo 2>/dev/null
		export TERM=xterm-256color
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		BELVE_SCRIPT_B64="$BELVE_SCRIPT_B64"
		CLAUDE_SCRIPT_B64="$CLAUDE_SCRIPT_B64"
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		$(typeset -f belve_tmux)
		$(typeset -f prepare_belve_tmux_session)
		$(typeset -f begin_remote_log)
		begin_remote_log
		write_remote_belve_files
		write_remote_bootstrap
		cd "$BELVE_REMOTE_PATH" || exit 1
		if command -v tmux >/dev/null 2>&1; then
		    belve_tmux start-server 2>/dev/null || true
		    belve_tmux set -s default-terminal xterm-256color 2>/dev/null
		    belve_tmux has-session -t "$TMUX_SESSION" 2>/dev/null || belve_tmux new-session -d -s "$TMUX_SESSION" -c "$BELVE_REMOTE_PATH" "\$HOME/.belve/session-bootstrap.sh"
		    prepare_belve_tmux_session "$TMUX_SESSION"
		    belve_tmux set -t "$TMUX_SESSION" status off 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" prefix None 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" mouse on 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" escape-time 0 2>/dev/null
		    belve_tmux setw -t "$TMUX_SESSION" pane-border-status off 2>/dev/null
		    belve_tmux bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    belve_tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    exec tmux -f /dev/null -L belve attach-session -d -t "$TMUX_SESSION"
		fi
		exec "\$HOME/.belve/session-bootstrap.sh"
		EOF
		    else
		        /usr/bin/ssh $SSH_OPTS -tt "$BELVE_SSH_HOST" /bin/bash <<EOF
		stty -echo 2>/dev/null
		export TERM=xterm-256color
		export BELVE_PROJECT_ID='${BELVE_PROJECT_ID:-}'
		export BELVE_PANE_INDEX='${BELVE_PANE_INDEX:-0}'
		export BELVE_PANE_ID='${BELVE_PANE_ID:-}'
		BELVE_SCRIPT_B64="$BELVE_SCRIPT_B64"
		CLAUDE_SCRIPT_B64="$CLAUDE_SCRIPT_B64"
		$(typeset -f decode_to_file)
		$(typeset -f write_remote_belve_files)
		$(typeset -f write_remote_bootstrap)
		$(typeset -f belve_tmux)
		$(typeset -f prepare_belve_tmux_session)
		$(typeset -f begin_remote_log)
		begin_remote_log
		write_remote_belve_files
		write_remote_bootstrap
		if command -v tmux >/dev/null 2>&1; then
		    belve_tmux start-server 2>/dev/null || true
		    belve_tmux set -s default-terminal xterm-256color 2>/dev/null
		    belve_tmux has-session -t "$TMUX_SESSION" 2>/dev/null || belve_tmux new-session -d -s "$TMUX_SESSION" "\$HOME/.belve/session-bootstrap.sh"
		    prepare_belve_tmux_session "$TMUX_SESSION"
		    belve_tmux set -t "$TMUX_SESSION" status off 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" prefix None 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" mouse on 2>/dev/null
		    belve_tmux set -t "$TMUX_SESSION" escape-time 0 2>/dev/null
		    belve_tmux setw -t "$TMUX_SESSION" pane-border-status off 2>/dev/null
		    belve_tmux bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    belve_tmux bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-selection 2>/dev/null
		    exec tmux -f /dev/null -L belve attach-session -d -t "$TMUX_SESSION"
		fi
		exec "\$HOME/.belve/session-bootstrap.sh"
		EOF
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
