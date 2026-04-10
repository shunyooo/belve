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
		SCP_OPTS="-o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10"
		SETUP_SSH="ssh -o ControlMaster=no -o ControlPath=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
		CONNECT_SSH="ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o SetEnv=TERM=xterm-256color -o ConnectTimeout=10"

		# Deploy a file via SCP with md5 checksum skip
		# Uses .new + mv to avoid "Text file busy" on running binaries
		deploy_file() {
		    local src="$1" host="$2" dst="$3"
		    [ -f "$src" ] || return 1
		    local local_md5=$(md5 -q "$src" 2>/dev/null || md5sum "$src" 2>/dev/null | cut -d' ' -f1)
		    local remote_md5=$($SETUP_SSH "$host" "md5sum '$dst' 2>/dev/null | cut -d' ' -f1" 2>/dev/null)
		    if [ "$local_md5" != "$remote_md5" ]; then
		        scp -q $SCP_OPTS "$src" "$host:${dst}.new" 2>/dev/null || return 1
		        $SETUP_SSH "$host" "mv -f '${dst}.new' '$dst'; chmod +x '$dst' 2>/dev/null" 2>/dev/null
		    fi
		}

		# Deploy belve-persist binary (architecture-aware)
		deploy_persist_binary() {
		    local host="$1"
		    local arch=$($SETUP_SSH "$host" "uname -m" 2>/dev/null)
		    local src_bin
		    if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
		        src_bin="$BELVE_BIN_DIR/belve-persist-linux-arm64"
		    else
		        src_bin="$BELVE_BIN_DIR/belve-persist-linux-amd64"
		    fi
		    deploy_file "$src_bin" "$host" "~/.belve/bin/belve-persist"
		}

		# SSH/DevContainer: SCP deploy + setup + connect
		if [ -n "$BELVE_SSH_HOST" ]; then
		    PROJ_SHORT=$(echo "$BELVE_PROJECT_ID" | cut -c1-8)
		    if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		        SESSION_NAME="belve-${PROJ_SHORT}"
		    else
		        SESSION_NAME="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		    fi

		    # Check if we can skip deploy+setup (session already exists)
		    NEED_SETUP=1
		    if $SETUP_SSH "$BELVE_SSH_HOST" "test -x ~/.belve/bin/belve-connect" 2>/dev/null; then
		        if [ -n "$BELVE_DEVCONTAINER" ]; then
		            $SETUP_SSH "$BELVE_SSH_HOST" "test -f ~/.belve/projects/${PROJ_SHORT}.env" 2>/dev/null && NEED_SETUP=0
		        else
		            NEED_SETUP=0
		        fi
		    fi

		    if [ "$NEED_SETUP" = "1" ]; then
		        # --- Phase 1: Deploy files via SCP ---
		        $SETUP_SSH "$BELVE_SSH_HOST" "mkdir -p ~/.belve/bin ~/.belve/sessions ~/.belve/zdotdir ~/.belve/projects"
		        deploy_persist_binary "$BELVE_SSH_HOST"
		        deploy_file "$BELVE_BIN_DIR/belve" "$BELVE_SSH_HOST" "~/.belve/bin/belve"
		        deploy_file "$BELVE_BIN_DIR/claude" "$BELVE_SSH_HOST" "~/.belve/bin/claude"
		        deploy_file "$BELVE_BIN_DIR/belve-setup" "$BELVE_SSH_HOST" "~/.belve/bin/belve-setup"
		        deploy_file "$BELVE_BIN_DIR/belve-connect" "$BELVE_SSH_HOST" "~/.belve/bin/belve-connect"
		        deploy_file "$BELVE_BIN_DIR/session-bootstrap.sh" "$BELVE_SSH_HOST" "~/.belve/session-bootstrap.sh"
		        $SETUP_SSH "$BELVE_SSH_HOST" "chmod +x ~/.belve/bin/* ~/.belve/session-bootstrap.sh 2>/dev/null"

		        # --- Phase 2: Setup (non-interactive SSH, single command) ---
		        SETUP_ARGS=""
		        if [ -n "$BELVE_DEVCONTAINER" ] && [ -n "$BELVE_REMOTE_PATH" ]; then
		            SETUP_ARGS="--devcontainer --workspace $BELVE_REMOTE_PATH --project-short $PROJ_SHORT"
		        fi
		        $SETUP_SSH "$BELVE_SSH_HOST" "\$HOME/.belve/bin/belve-setup $SETUP_ARGS"
		        [ $? -eq 0 ] || { echo "Setup failed"; exit 1; }
		    fi

		    # --- Connect (interactive SSH, single command) ---
		    CONNECT_ARGS="--session $SESSION_NAME --cols ${BELVE_COLS:-80} --rows ${BELVE_ROWS:-24}"
		    CONNECT_ARGS="$CONNECT_ARGS --project-id ${BELVE_PROJECT_ID:-} --pane-index ${BELVE_PANE_INDEX:-0} --pane-id ${BELVE_PANE_ID:-}"
		    if [ -n "$BELVE_DEVCONTAINER" ]; then
		        CONNECT_ARGS="$CONNECT_ARGS --devcontainer --project-short $PROJ_SHORT"
		    elif [ -n "$BELVE_REMOTE_PATH" ]; then
		        CONNECT_ARGS="$CONNECT_ARGS --workdir $BELVE_REMOTE_PATH"
		    fi
		    $CONNECT_SSH -tt "$BELVE_SSH_HOST" "\$HOME/.belve/bin/belve-connect $CONNECT_ARGS"

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
		PERSIST_SOCK="\#(tmpDir)/sessions/${LOCAL_SESSION}.sock"
		mkdir -p "\#(tmpDir)/sessions"

		if [ -x "$PERSIST_BIN" ]; then
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
