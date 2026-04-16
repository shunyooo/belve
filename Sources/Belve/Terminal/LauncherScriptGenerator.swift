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
		BELVE_SSH_CONTROL="/tmp/belve-ssh-ctrl-%r@%h:%p"
		SETUP_COMMON="-o ControlMaster=auto -o ControlPath=$BELVE_SSH_CONTROL -o ControlPersist=30 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
		SCP_OPTS="$SETUP_COMMON"
		SETUP_SSH="ssh $SETUP_COMMON"
		# Connect reuses ControlMaster from setup phase for instant connection.
		# SIGWINCH propagation is handled by belve-persist TCP protocol, not SSH.
		CONNECT_SSH="ssh $SETUP_COMMON -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o TCPKeepAlive=yes -o SetEnv=TERM=xterm-256color"

		# Deploy all scripts + persist binaries in a single SCP+SSH.
		# Includes both arch binaries; remote selects the correct one.
		# Uses md5 of the tar to skip if unchanged.
		deploy_bundle() {
		    local host="$1"
		    local tmptar="/tmp/belve-deploy-$$.tar.gz"

		    # Build tar with all deploy files (both arch binaries included)
		    local staging="/tmp/belve-stage-$$"
		    mkdir -p "$staging/bin"
		    cp "$BELVE_BIN_DIR/belve" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/claude" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/codex" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/belve-connect" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/belve-setup" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/belve-persist-linux-amd64" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/belve-persist-linux-arm64" "$staging/bin/"
		    cp "$BELVE_BIN_DIR/session-bootstrap.sh" "$staging/"
		    tar czf "$tmptar" -C "$staging" .
		    rm -rf "$staging"

		    # Check if remote already has the same bundle
		    local local_md5=$(md5 -q "$tmptar" 2>/dev/null || md5sum "$tmptar" 2>/dev/null | cut -d' ' -f1)

		    # Single SCP + single SSH (no prior SSH needed)
		    if ! scp -q $SCP_OPTS "$tmptar" "$host:/tmp/belve-deploy.tar.gz"; then
		        echo "[belve] deploy_bundle: SCP FAILED" >&2
		        rm -f "$tmptar"
		        return 1
		    fi
		    rm -f "$tmptar"

		    $SETUP_SSH "$host" "
		        if [ -f ~/.belve/.deploy-md5 ] && [ \"\$(cat ~/.belve/.deploy-md5)\" = '$local_md5' ]; then
		            rm -f /tmp/belve-deploy.tar.gz
		            exit 0
		        fi
		        mkdir -p ~/.belve/bin ~/.belve/sessions ~/.belve/zdotdir ~/.belve/projects
		        tar xzf /tmp/belve-deploy.tar.gz -C ~/.belve
		        ARCH=\$(uname -m)
		        if [ \"\$ARCH\" = 'aarch64' ] || [ \"\$ARCH\" = 'arm64' ]; then
		            mv -f ~/.belve/bin/belve-persist-linux-arm64 ~/.belve/bin/belve-persist
		        else
		            mv -f ~/.belve/bin/belve-persist-linux-amd64 ~/.belve/bin/belve-persist
		        fi
		        rm -f ~/.belve/bin/belve-persist-linux-amd64 ~/.belve/bin/belve-persist-linux-arm64
		        chmod +x ~/.belve/bin/* ~/.belve/session-bootstrap.sh 2>/dev/null
		        echo '$local_md5' > ~/.belve/.deploy-md5
		        rm -f /tmp/belve-deploy.tar.gz
		    " 2>/dev/null
		}

		# SSH/DevContainer: SCP deploy + setup + connect
		if [ -n "$BELVE_SSH_HOST" ]; then
		    PROJ_SHORT=$(echo "$BELVE_PROJECT_ID" | cut -c1-8)
		    if [ "${BELVE_PANE_INDEX:-0}" = "0" ]; then
		        SESSION_NAME="belve-${PROJ_SHORT}"
		    else
		        SESSION_NAME="belve-${PROJ_SHORT}-${BELVE_PANE_INDEX}"
		    fi

		    # Status reporting for loading UI
		    belve_status() { printf '\x1b]9;belve-status;%s\x07' "$1"; }

		    belve_status "Connecting to $BELVE_SSH_HOST..."

		    # Deploy all files in a single tar (1 SCP + 1 SSH)
		    deploy_bundle "$BELVE_SSH_HOST"

		    # Run setup if needed (DevContainer: devcontainer up + container deploy)
		    NEED_SETUP=1
		    if [ -n "$BELVE_DEVCONTAINER" ]; then
		        $SETUP_SSH "$BELVE_SSH_HOST" "test -f ~/.belve/projects/${PROJ_SHORT}.env" 2>/dev/null && NEED_SETUP=0
		    else
		        NEED_SETUP=0
		    fi

		    if [ "$NEED_SETUP" = "1" ]; then
		        if [ -n "$BELVE_DEVCONTAINER" ]; then
		            belve_status "Starting DevContainer..."
		        else
		            belve_status "Setting up remote environment..."
		        fi
		        SETUP_ARGS=""
		        if [ -n "$BELVE_DEVCONTAINER" ] && [ -n "$BELVE_WORKDIR" ]; then
		            SETUP_ARGS="--devcontainer --workspace $BELVE_WORKDIR --project-short $PROJ_SHORT"
		        fi
		        $SETUP_SSH "$BELVE_SSH_HOST" "\$HOME/.belve/bin/belve-setup $SETUP_ARGS"
		        [ $? -eq 0 ] || { belve_status "Setup failed"; echo "Setup failed"; exit 1; }
		    fi

		    # --- Connect (interactive SSH, single command) ---
		    # Ensure ControlMaster is ready before connecting
		    ssh -o ControlPath="$BELVE_SSH_CONTROL" -O check "$BELVE_SSH_HOST" 2>/dev/null || \
		        $SETUP_SSH "$BELVE_SSH_HOST" "true" 2>/dev/null
		    belve_status "Attaching session..."
		    CONNECT_ARGS="--session $SESSION_NAME --cols ${BELVE_COLS:-80} --rows ${BELVE_ROWS:-24}"
		    CONNECT_ARGS="$CONNECT_ARGS --project-id ${BELVE_PROJECT_ID:-} --pane-index ${BELVE_PANE_INDEX:-0} --pane-id ${BELVE_PANE_ID:-}"
		    if [ -n "$BELVE_DEVCONTAINER" ]; then
		        CONNECT_ARGS="$CONNECT_ARGS --devcontainer --project-short $PROJ_SHORT"
		    elif [ -n "$BELVE_WORKDIR" ]; then
		        CONNECT_ARGS="$CONNECT_ARGS --workdir $BELVE_WORKDIR"
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
