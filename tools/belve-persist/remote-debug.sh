#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SELF_DIR/../.." && pwd)"

SSH_HOST="${SSH_HOST:-}"
CID="${CID:-}"
PANE_ID="${PANE_ID:-}"
TRACE_DIR="${TRACE_DIR:-/tmp/belve-trace}"
WATCH_OUTPUT="${WATCH_OUTPUT:-/tmp/belve-pane-watch.log}"
REMOTE_BIN_DIR="${REMOTE_BIN_DIR:-$HOME/.belve/bin}"
CONTAINER_BIN_DIR="${CONTAINER_BIN_DIR:-/root/.belve/bin}"

usage() {
    cat <<'EOF'
Usage:
  remote-debug.sh <command> [options]

Commands:
  build
      Build tools/belve-persist/belve-persist-linux-amd64 locally.

  deploy
      Copy belve-persist-linux-amd64, trace-broker.sh, and watch-pane.sh
      to the VM and into the target container.

  start-broker-trace
      Kill the current container broker, clear old trace output, and start
      belve-persist under trace-broker.sh inside the container.

  start-watch [--pid PID | --session SESSION_NAME | --pane-id PANE_ID]
      Start watch-pane.sh inside the container for the target process.

  status
      Show host/container belve-persist processes and trace file listings.

  fetch [DEST_DIR]
      Copy trace output back from the VM into DEST_DIR
      (default: ./tmp/remote-debug-YYYYmmdd-HHMMSS).

Environment:
  SSH_HOST   Required. Remote SSH host.
  CID        Required. Target container ID.
  PANE_ID    Optional fallback for start-watch --pane-id.
  TRACE_DIR  Default: /tmp/belve-trace
  WATCH_OUTPUT Default: /tmp/belve-pane-watch.log

Examples:
  SSH_HOST=host CID=container tools/belve-persist/remote-debug.sh build
  SSH_HOST=host CID=container tools/belve-persist/remote-debug.sh deploy
  SSH_HOST=host CID=container tools/belve-persist/remote-debug.sh start-broker-trace
  SSH_HOST=host CID=container tools/belve-persist/remote-debug.sh start-watch --session belve-28CA2F90-3
  SSH_HOST=host CID=container tools/belve-persist/remote-debug.sh fetch
EOF
}

require_ssh_host() {
    if [ -z "$SSH_HOST" ]; then
        echo "SSH_HOST is required" >&2
        exit 2
    fi
}

require_container() {
    require_ssh_host
    if [ -z "$CID" ]; then
        echo "CID is required" >&2
        exit 2
    fi
}

ssh_host() {
    require_ssh_host
    ssh "$SSH_HOST" "$@"
}

scp_to_host() {
    require_ssh_host
    scp "$1" "$SSH_HOST:$2"
}

scp_from_host() {
    require_ssh_host
    scp "$SSH_HOST:$1" "$2"
}

build_local() {
    (
        cd "$SELF_DIR"
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o belve-persist-linux-amd64 .
    )
}

deploy_all() {
    require_container

    local local_bin="$SELF_DIR/belve-persist-linux-amd64"
    local trace_script="$SELF_DIR/trace-broker.sh"
    local watch_script="$SELF_DIR/watch-pane.sh"

    if [ ! -x "$local_bin" ]; then
        echo "missing $local_bin, run: $0 build" >&2
        exit 2
    fi

    ssh "$SSH_HOST" "mkdir -p ~/.belve/bin"

    scp_to_host "$local_bin" "/tmp/belve-persist-linux-amd64.new"
    scp_to_host "$trace_script" "/tmp/trace-broker.sh.new"
    scp_to_host "$watch_script" "/tmp/watch-pane.sh.new"

    ssh "$SSH_HOST" /bin/bash -s <<'EOF'
set -euo pipefail
mv /tmp/belve-persist-linux-amd64.new ~/.belve/bin/belve-persist
mv /tmp/trace-broker.sh.new ~/.belve/bin/trace-broker.sh
mv /tmp/watch-pane.sh.new ~/.belve/bin/watch-pane.sh
chmod +x ~/.belve/bin/belve-persist ~/.belve/bin/trace-broker.sh ~/.belve/bin/watch-pane.sh
EOF

    ssh "$SSH_HOST" /bin/bash -s <<EOF
set -euo pipefail
docker cp ~/.belve/bin/belve-persist '$CID:$CONTAINER_BIN_DIR/belve-persist'
docker cp ~/.belve/bin/trace-broker.sh '$CID:$CONTAINER_BIN_DIR/trace-broker.sh'
docker cp ~/.belve/bin/watch-pane.sh '$CID:$CONTAINER_BIN_DIR/watch-pane.sh'
docker exec '$CID' chmod +x '$CONTAINER_BIN_DIR/belve-persist' '$CONTAINER_BIN_DIR/trace-broker.sh' '$CONTAINER_BIN_DIR/watch-pane.sh'
EOF
}

start_broker_trace() {
    require_container

    ssh "$SSH_HOST" /bin/bash -s <<EOF
set -euo pipefail
docker exec '$CID' pkill -f 'belve-persist.*tcplisten' 2>/dev/null || true
docker exec '$CID' rm -rf '$TRACE_DIR'
docker exec '$CID' mkdir -p '$TRACE_DIR'
docker exec -d '$CID' /bin/bash -lc "set -euo pipefail; if ! command -v strace >/dev/null 2>&1; then echo strace-not-found > '$TRACE_DIR/launcher.log'; exit 127; fi; nohup '$CONTAINER_BIN_DIR/trace-broker.sh' --trace-dir '$TRACE_DIR' -- '$CONTAINER_BIN_DIR/belve-persist' -tcplisten 0.0.0.0:19222 -command /root/.belve/session-bootstrap.sh > '$TRACE_DIR/launcher.log' 2>&1 &"
EOF
}

start_watch() {
    require_container

    local pane=""
    local pid=""
    local session=""
    while (($# > 0)); do
        case "$1" in
            --pane-id)
                pane="${2:?missing pane id}"
                shift 2
                ;;
            --pid)
                pid="${2:?missing pid}"
                shift 2
                ;;
            --session)
                session="${2:?missing session name}"
                shift 2
                ;;
            *)
                echo "unknown option for start-watch: $1" >&2
                exit 2
                ;;
        esac
    done

    if [ -z "$pane" ] && [ -z "$pid" ] && [ -z "$session" ]; then
        pane="$PANE_ID"
    fi
    mode_count=0
    [ -n "$pane" ] && mode_count=$((mode_count + 1))
    [ -n "$pid" ] && mode_count=$((mode_count + 1))
    [ -n "$session" ] && mode_count=$((mode_count + 1))
    if [ "$mode_count" -gt 1 ]; then
        echo "use only one of --pane-id, --pid, --session" >&2
        exit 2
    fi
    if [ "$mode_count" -eq 0 ]; then
        echo "pid, session, or pane id is required" >&2
        exit 2
    fi

    local mode_flag=""
    local mode_value=""
    if [ -n "$pid" ]; then
        mode_flag="--pid"
        mode_value="$pid"
    elif [ -n "$pane" ]; then
        mode_flag="--pane-id"
        mode_value="$pane"
    else
        mode_flag="--session"
        mode_value="$session"
    fi

    ssh "$SSH_HOST" /bin/bash -s <<EOF
set -euo pipefail
docker exec '$CID' rm -f '$WATCH_OUTPUT'
docker exec -d '$CID' "$CONTAINER_BIN_DIR/watch-pane.sh" $mode_flag "$mode_value" --output '$WATCH_OUTPUT'
EOF
}

show_status() {
    require_container

    ssh "$SSH_HOST" /bin/bash -s <<EOF
set -euo pipefail
echo '== host belve-persist =='
ps aux | grep belve-persist | grep -v grep || true
echo
echo '== container belve-persist =='
docker exec '$CID' ps aux | grep belve-persist | grep -v grep || true
echo
echo '== container trace dir =='
docker exec '$CID' /bin/bash -c 'ls -lah "$TRACE_DIR" 2>/dev/null || true'
echo
echo '== watch output =='
docker exec '$CID' /bin/bash -c 'ls -lah "$WATCH_OUTPUT" 2>/dev/null || true'
EOF
}

fetch_logs() {
    require_container

    local dest="${1:-}"
    if [ -z "$dest" ]; then
        dest="$ROOT_DIR/tmp/remote-debug-$(date +%Y%m%d-%H%M%S)"
    fi

    mkdir -p "$dest"

    ssh "$SSH_HOST" /bin/bash -s <<EOF
set -euo pipefail
rm -rf /tmp/belve-debug-fetch
mkdir -p /tmp/belve-debug-fetch
docker cp '$CID:$TRACE_DIR' /tmp/belve-debug-fetch/trace 2>/dev/null || true
docker cp '$CID:$WATCH_OUTPUT' /tmp/belve-debug-fetch/watch.log 2>/dev/null || true
tar -C /tmp/belve-debug-fetch -czf /tmp/belve-debug-fetch.tgz .
EOF

    scp_from_host "/tmp/belve-debug-fetch.tgz" "$dest/belve-debug-fetch.tgz"

    (
        cd "$dest"
        tar -xzf belve-debug-fetch.tgz
    )
}

command="${1:-}"
if [ -z "$command" ]; then
    usage >&2
    exit 2
fi
shift || true

case "$command" in
    build)
        build_local
        ;;
    deploy)
        deploy_all
        ;;
    start-broker-trace)
        start_broker_trace
        ;;
    start-watch)
        start_watch "$@"
        ;;
    status)
        show_status
        ;;
    fetch)
        fetch_logs "${1:-}"
        ;;
    --help|-h|help)
        usage
        ;;
    *)
        echo "unknown command: $command" >&2
        usage >&2
        exit 2
        ;;
esac
