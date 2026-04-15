#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  trace-broker.sh [--trace-dir DIR] -- <belve-persist> [args...]

Example:
  trace-broker.sh --trace-dir /tmp/belve-trace -- \
    /root/.belve/bin/belve-persist \
    -tcplisten 0.0.0.0:19222 \
    -command /root/.belve/session-bootstrap.sh

This wraps belve-persist with strace and writes:
  - strace logs per PID
  - ps snapshots every second
  - lightweight environment metadata
EOF
}

trace_dir=""

while (($# > 0)); do
    case "$1" in
        --trace-dir)
            trace_dir="${2:?missing trace dir}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if (($# == 0)); then
    usage >&2
    exit 2
fi

if ! command -v strace >/dev/null 2>&1; then
    echo "strace not found" >&2
    exit 127
fi

if [ -z "$trace_dir" ]; then
    trace_dir="/tmp/belve-trace-$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p "$trace_dir"

{
    echo "date=$(date -Ins)"
    echo "hostname=$(hostname 2>/dev/null || true)"
    echo "id=$(id)"
    echo "pwd=$(pwd)"
    echo "cmd=$*"
    echo "kernel=$(uname -a)"
} >"$trace_dir/meta.txt"

(
    while :; do
        {
            echo "=== $(date -Ins) ==="
            ps -eo pid,ppid,pgid,sid,tpgid,tty,stat,etimes,comm,args --forest
            echo
        } >>"$trace_dir/ps.log"
        sleep 1
    done
) &
ps_watcher=$!

cleanup() {
    kill "$ps_watcher" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

exec strace \
    -ff \
    -ttT \
    -s 128 \
    -yy \
    -o "$trace_dir/strace" \
    -e trace=kill,tgkill,tkill,pidfd_send_signal,wait4,clone,fork,vfork,execve,exit_group,prctl \
    "$@"
