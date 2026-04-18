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
		# Literal path (not template) so Swift-side SSHTunnelManager can share the same ControlMaster
		BELVE_SSH_CONTROL="/tmp/belve-ssh-ctrl-$BELVE_SSH_HOST"
		SETUP_COMMON="-o ControlMaster=auto -o ControlPath=$BELVE_SSH_CONTROL -o ControlPersist=600 -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
		SCP_OPTS="$SETUP_COMMON"
		SETUP_SSH="ssh $SETUP_COMMON"
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

		    # Serialize deploy across all projects (mkdir-based lock)
		    DEPLOY_LOCK="/tmp/belve-deploy.lock"
		    while ! mkdir "$DEPLOY_LOCK" 2>/dev/null; do sleep 0.2; done
		    trap "rmdir '$DEPLOY_LOCK' 2>/dev/null" EXIT

		    # Ensure ControlMaster is established (skip if already exists)
		    if ! ssh -o ControlPath="$BELVE_SSH_CONTROL" -O check "$BELVE_SSH_HOST" 2>/dev/null; then
		        ssh -o ControlMaster=yes -o ControlPath="$BELVE_SSH_CONTROL" -o ControlPersist=600 \
		            -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
		            -fN "$BELVE_SSH_HOST" 2>/dev/null || true
		    fi

		    # Deploy all files in a single tar (1 SCP + 1 SSH)
		    deploy_bundle "$BELVE_SSH_HOST"
		    rmdir "$DEPLOY_LOCK" 2>/dev/null
		    trap - EXIT

		    # Always run belve-setup — it's idempotent. Fast path (container running) just
		    # ensures the broker is alive; slow path (first connect / rebuilt) runs `devcontainer up`.
		    if [ -n "$BELVE_DEVCONTAINER" ]; then
		        belve_status "Preparing DevContainer..."
		        SETUP_ARGS="--devcontainer --workspace $BELVE_WORKDIR --project-short $PROJ_SHORT"
		        $SETUP_SSH "$BELVE_SSH_HOST" "\$HOME/.belve/bin/belve-setup $SETUP_ARGS" \
		            || { belve_status "Setup failed"; echo "Setup failed"; exit 1; }
		    else
		        belve_status "Preparing remote broker..."
		        $SETUP_SSH "$BELVE_SSH_HOST" "\$HOME/.belve/bin/belve-setup" \
		            || { belve_status "Setup failed"; echo "Setup failed"; exit 1; }
		    fi

		    # --- Establish SSH port forward to broker (ssh -O forward on existing ControlMaster) ---
		    # Swift (SSHTunnelManager.reservePort) pre-allocated BELVE_LOCAL_BROKER_PORT and will
		    # cancel the forward on project close / app exit.
		    if [ -z "${BELVE_LOCAL_BROKER_PORT:-}" ]; then
		        belve_status "Port not reserved"
		        echo "[belve] ERROR: BELVE_LOCAL_BROKER_PORT not set" >&2
		        exit 1
		    fi

		    if [ -n "$BELVE_DEVCONTAINER" ]; then
		        # Read container IP from project env file on VM
		        CIP=$($SETUP_SSH "$BELVE_SSH_HOST" ". ~/.belve/projects/${PROJ_SHORT}.env && echo \"\$CIP\"" 2>/dev/null | tr -d '\r\n')
		        if [ -z "$CIP" ]; then
		            belve_status "Container not ready"
		            echo "[belve] ERROR: container IP not found in ~/.belve/projects/${PROJ_SHORT}.env" >&2
		            exit 1
		        fi
		        FORWARD_TARGET="$CIP:19222"
		    else
		        FORWARD_TARGET="127.0.0.1:19222"
		    fi

		    # Add port forward. Cancel any forward spec recorded from a previous session
		    # (SSHTunnelManager writes ${projId}.spec with the last-used target, so we can
		    # cancel it precisely even if the CIP has changed across restarts/rebuilds).
		    SPEC_DIR="\#(tmpDir)/tunnels"
		    mkdir -p "$SPEC_DIR"
		    SPEC_FILE="$SPEC_DIR/${BELVE_PROJECT_ID}.spec"
		    if [ -f "$SPEC_FILE" ]; then
		        STALE_SPEC=$(cat "$SPEC_FILE")
		        [ -n "$STALE_SPEC" ] && ssh -o ControlPath="$BELVE_SSH_CONTROL" -O cancel -L "$STALE_SPEC" "$BELVE_SSH_HOST" 2>/dev/null || true
		    fi
		    # Also try cancel with the new spec (handles the first-forward case where no stale exists)
		    ssh -o ControlPath="$BELVE_SSH_CONTROL" -O cancel -L "$BELVE_LOCAL_BROKER_PORT:$FORWARD_TARGET" "$BELVE_SSH_HOST" 2>/dev/null || true
		    FORWARD_ERR=$(ssh -o ControlPath="$BELVE_SSH_CONTROL" -O forward -L "$BELVE_LOCAL_BROKER_PORT:$FORWARD_TARGET" "$BELVE_SSH_HOST" 2>&1)
		    if [ $? -ne 0 ]; then
		        belve_status "Forward failed"
		        echo "[belve] ERROR: ssh -O forward -L $BELVE_LOCAL_BROKER_PORT:$FORWARD_TARGET failed: $FORWARD_ERR" >&2
		        exit 1
		    fi
		    # Record actual forward spec so Swift's teardownTunnel can cancel precisely later
		    printf '%s' "$BELVE_LOCAL_BROKER_PORT:$FORWARD_TARGET" > "$SPEC_FILE"

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

		    # 1) Start tcpbackend daemon in the background (detached, no tty)
		    nohup "$PERSIST_BIN" -socket "$PERSIST_SOCK" \
		        -cols "${BELVE_COLS:-80}" -rows "${BELVE_ROWS:-24}" \
		        -tcpbackend "127.0.0.1:$BELVE_LOCAL_BROKER_PORT" \
		        -session "$SESSION_NAME" >/dev/null 2>&1 &
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
