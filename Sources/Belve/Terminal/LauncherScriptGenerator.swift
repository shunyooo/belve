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
		let shell = resolveUserShell()
		let shellName = (shell as NSString).lastPathComponent
		let tmpDir = "/tmp/belve-shell"
		try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

		let launcher = "\(tmpDir)/belve-launcher.sh"
		try? #"""
		#!/bin/sh
		export TERM=xterm-256color
		SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ControlMaster=auto -o ControlPath=/tmp/belve-ssh-%r@%h:%p -o ControlPersist=600"

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
		    TMUX_APPLY="tmux set -t $TMUX_SESSION status off; tmux set -t $TMUX_SESSION prefix None; tmux set -t $TMUX_SESSION mouse off; tmux set -t $TMUX_SESSION escape-time 0; tmux setw -t $TMUX_SESSION pane-border-status off"

		    if [ -n "$BELVE_DEVCONTAINER" ] && [ -n "$BELVE_REMOTE_PATH" ]; then
		        # DevContainer: use tmux inside the container for session persistence
		        /usr/bin/ssh $SSH_OPTS -t "$BELVE_SSH_HOST" "export TERM=xterm-256color; cd $BELVE_REMOTE_PATH && devcontainer up --workspace-folder . >/dev/null 2>&1 && devcontainer exec --workspace-folder . sh -c 'S=$TMUX_SESSION; if command -v tmux >/dev/null 2>&1; then tmux has-session -t \$S 2>/dev/null || tmux new-session -d -s \$S; tmux set -t \$S status off 2>/dev/null; tmux set -t \$S prefix None 2>/dev/null; tmux set -t \$S mouse off 2>/dev/null; tmux set -t \$S escape-time 0 2>/dev/null; tmux setw -t \$S pane-border-status off 2>/dev/null; exec tmux attach -t \$S; else exec \$SHELL -l; fi' 2>/dev/null"
		    elif [ -n "$BELVE_REMOTE_PATH" ]; then
		        # Create or attach to existing tmux session, apply transparent settings
		        /usr/bin/ssh $SSH_OPTS -t "$BELVE_SSH_HOST" "export TERM=xterm-256color; command -v tmux >/dev/null && { tmux has-session -t $TMUX_SESSION 2>/dev/null || tmux new-session -d -s $TMUX_SESSION -c $BELVE_REMOTE_PATH; $TMUX_APPLY; exec tmux attach -t $TMUX_SESSION; } || { cd $BELVE_REMOTE_PATH && exec \$SHELL -l; }"
		    else
		        /usr/bin/ssh $SSH_OPTS -t "$BELVE_SSH_HOST" "command -v tmux >/dev/null && { tmux has-session -t $TMUX_SESSION 2>/dev/null || tmux new-session -d -s $TMUX_SESSION; $TMUX_APPLY; exec tmux attach -t $TMUX_SESSION; } || exec \$SHELL -l"
		    fi
		    # SSH exited — fall through to local shell below
		    echo "🔌 SSH disconnected. Local shell:"
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
