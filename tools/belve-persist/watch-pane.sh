#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  watch-pane.sh --pane-id PANE_ID [--interval SEC] [--output FILE]
  watch-pane.sh --pid PID [--interval SEC] [--output FILE]
  watch-pane.sh --session SESSION_NAME [--interval SEC] [--output FILE]

Examples:
  watch-pane.sh --pane-id belve-28CA2F90-3
  watch-pane.sh --pid 4051103 --output /tmp/pane-watch.log
  watch-pane.sh --session belve-28CA2F90-3

This writes repeated snapshots of:
  - pid/ppid/pgid/sid/tpgid/tty
  - /proc/<pid>/status
  - /proc/<pid>/limits
  - /proc/<pid>/cgroup
  - direct child processes
EOF
}

pane_id=""
target_pid=""
session_name=""
interval="1"
output=""

while (($# > 0)); do
    case "$1" in
        --pane-id)
            pane_id="${2:?missing pane id}"
            shift 2
            ;;
        --pid)
            target_pid="${2:?missing pid}"
            shift 2
            ;;
        --session)
            session_name="${2:?missing session name}"
            shift 2
            ;;
        --interval)
            interval="${2:?missing interval}"
            shift 2
            ;;
        --output)
            output="${2:?missing output path}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mode_count=0
[ -n "$pane_id" ] && mode_count=$((mode_count + 1))
[ -n "$target_pid" ] && mode_count=$((mode_count + 1))
[ -n "$session_name" ] && mode_count=$((mode_count + 1))

if [ "$mode_count" -gt 1 ]; then
    echo "use only one of --pane-id, --pid, --session" >&2
    exit 2
fi

if [ "$mode_count" -eq 0 ]; then
    echo "one of --pane-id, --pid, --session is required" >&2
    exit 2
fi

if [ -z "$output" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    if [ -n "$pane_id" ]; then
        output="/tmp/watch-${pane_id}-${stamp}.log"
    elif [ -n "$session_name" ]; then
        output="/tmp/watch-session-${session_name}-${stamp}.log"
    else
        output="/tmp/watch-pid-${target_pid}-${stamp}.log"
    fi
fi

resolve_pid() {
    if [ -n "$target_pid" ]; then
        printf '%s\n' "$target_pid"
        return
    fi

    if [ -n "$session_name" ]; then
        if [ -f /tmp/belve-persist-broker.log ]; then
            grep "$session_name.*child started" /tmp/belve-persist-broker.log 2>/dev/null \
                | tail -1 \
                | grep -o 'pid=[0-9]*' \
                | cut -d= -f2
        fi
        return
    fi

    local pidfile="$HOME/.belve/panes/$pane_id.pid"
    if [ -f "$pidfile" ]; then
        cat "$pidfile"
        return
    fi

    for d in /proc/[0-9]*/environ; do
        [ -r "$d" ] || continue
        if grep -qz "BELVE_PANE_ID=$pane_id" "$d" 2>/dev/null; then
            local pid="${d#/proc/}"
            pid="${pid%%/environ}"
            printf '%s\n' "$pid"
            return
        fi
    done
}

{
    echo "# watch start $(date -Ins)"
    echo "# output=$output"
    echo "# interval=$interval"
    if [ -n "$pane_id" ]; then
        echo "# pane_id=$pane_id"
    fi
    if [ -n "$target_pid" ]; then
        echo "# pid=$target_pid"
    fi
    if [ -n "$session_name" ]; then
        echo "# session=$session_name"
    fi
} >>"$output"

while :; do
    pid="$(resolve_pid || true)"
    {
        echo "=== $(date -Ins) ==="
        echo "resolved_pid=${pid:-}"
        if [ -n "${pid:-}" ] && [ -d "/proc/$pid" ]; then
            ps -o pid=,ppid=,pgid=,sid=,tpgid=,tty=,stat=,etimes=,comm=,args= -p "$pid"
            echo "--- status ---"
            sed -n '1,60p' "/proc/$pid/status"
            echo "--- limits ---"
            sed -n '1,40p' "/proc/$pid/limits"
            echo "--- cgroup ---"
            cat "/proc/$pid/cgroup"
            echo "--- fd0 ---"
            readlink "/proc/$pid/fd/0" 2>/dev/null || true
            echo "--- children ---"
            ps -eo pid,ppid,pgid,sid,tpgid,tty,stat,etimes,comm,args | awk -v pid="$pid" '$2 == pid'
        else
            echo "process missing"
        fi
        echo
    } >>"$output"
    sleep "$interval"
done
