#!/bin/sh
# session-bootstrap.sh: shell initialization for Belve sessions
# Environment expected: BELVE_SESSION, BELVE_PROJECT_ID, BELVE_PANE_INDEX, BELVE_PANE_ID
# These are inherited from the caller (belve-connect or docker exec -e)

export BELVE_SESSION="${BELVE_SESSION:-1}"
export PATH="$HOME/.belve/bin:$PATH"
export BELVE_TTY=$(tty 2>/dev/null || echo "")

# Workaround for Claude Code v2.1.x SessionStart bug. Also handle the case where
# ~/.claude is a symlink to a workspace path whose target doesn't exist yet.
if [ -L "$HOME/.claude" ] && [ ! -e "$HOME/.claude" ]; then
    _link=$(readlink "$HOME/.claude" 2>/dev/null || echo "")
    case "$_link" in
        /*) mkdir -p "$_link/session-env" 2>/dev/null || true ;;
        ?*) mkdir -p "$(dirname "$HOME/.claude")/$_link/session-env" 2>/dev/null || true ;;
    esac
    unset _link
fi
mkdir -p "$HOME/.claude/session-env" 2>/dev/null || true

# Write PID file for fast resize lookup (avoids slow /proc/*/environ scan)
if [ -n "$BELVE_PANE_ID" ]; then
    mkdir -p "$HOME/.belve/panes"
    echo $$ > "$HOME/.belve/panes/$BELVE_PANE_ID.pid"
fi

SHELL_PATH="${SHELL:-/bin/bash}"
SHELL_NAME="$(basename "$SHELL_PATH")"

case "$SHELL_NAME" in
  bash)
    cat > "$HOME/.belve/belve-bashrc" <<'BASHRC'
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
export PATH="$HOME/.belve/bin:$PATH"
# Workaround for Claude Code SessionStart mkdir bug
mkdir -p "$HOME/.claude/session-env" 2>/dev/null || true
# Belve: auto-source .env on cd or when .env is edited (unsets prev keys on reload)
_belve_load_env() {
    local _m=""
    [ -f ./.env ] && _m=$(stat -f %m ./.env 2>/dev/null || stat -c %Y ./.env 2>/dev/null)
    local _k="$PWD:$_m"
    [ "$_k" = "${_BELVE_LAST_ENV_KEY:-}" ] && return
    _BELVE_LAST_ENV_KEY="$_k"
    if [ -n "${_BELVE_ENV_KEYS:-}" ]; then
        for _ek in $_BELVE_ENV_KEYS; do unset "$_ek"; done
    fi
    _BELVE_ENV_KEYS=""
    if [ -f ./.env ]; then
        set -a; . ./.env; set +a
        _BELVE_ENV_KEYS=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' ./.env | tr '\n' ' ')
    fi
}
PROMPT_COMMAND="_belve_load_env${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
_belve_load_env
BASHRC
    exec "$SHELL_PATH" --rcfile "$HOME/.belve/belve-bashrc" -i ;;
  zsh)
    mkdir -p "$HOME/.belve/zdotdir"
    cat > "$HOME/.belve/zdotdir/.zshenv" <<'ZENV'
[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv"
ZENV
    cat > "$HOME/.belve/zdotdir/.zprofile" <<'ZPROF'
[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile"
ZPROF
    cat > "$HOME/.belve/zdotdir/.zshrc" <<'ZSHRC'
[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
export PATH="$HOME/.belve/bin:$PATH"
# Workaround for Claude Code SessionStart mkdir bug
mkdir -p "$HOME/.claude/session-env" 2>/dev/null || true
# Belve: auto-source .env on cd or when .env is edited (unsets prev keys on reload)
_belve_load_env() {
    local _m=""
    [ -f ./.env ] && _m=$(stat -f %m ./.env 2>/dev/null || stat -c %Y ./.env 2>/dev/null)
    local _k="$PWD:$_m"
    [ "$_k" = "${_BELVE_LAST_ENV_KEY:-}" ] && return
    _BELVE_LAST_ENV_KEY="$_k"
    if [ -n "${_BELVE_ENV_KEYS:-}" ]; then
        for _ek in ${=_BELVE_ENV_KEYS}; do unset "$_ek"; done
    fi
    _BELVE_ENV_KEYS=""
    if [ -f ./.env ]; then
        set -a; . ./.env; set +a
        _BELVE_ENV_KEYS=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' ./.env | tr '\n' ' ')
    fi
}
autoload -U add-zsh-hook
add-zsh-hook precmd _belve_load_env
_belve_load_env
ZSHRC
    exec env ZDOTDIR="$HOME/.belve/zdotdir" "$SHELL_PATH" -l -i ;;
  fish)
    exec "$SHELL_PATH" --init-command 'set -gx PATH "$HOME/.belve/bin" $PATH' ;;
  *)
    exec env PATH="$HOME/.belve/bin:$PATH" "$SHELL_PATH" -l -i ;;
esac
