#!/bin/sh
# session-bootstrap.sh: shell initialization for Belve sessions
# Environment expected: BELVE_SESSION, BELVE_PROJECT_ID, BELVE_PANE_INDEX, BELVE_PANE_ID
# These are inherited from the caller (belve-connect or docker exec -e)

export BELVE_SESSION="${BELVE_SESSION:-1}"
export PATH="$HOME/.belve/bin:$PATH"
export BELVE_TTY=$(tty 2>/dev/null || echo "")
if [ -n "$BELVE_WORKDIR" ]; then
    case "$BELVE_WORKDIR" in "~"*) BELVE_WORKDIR="$HOME${BELVE_WORKDIR#"~"}" ;; esac
    cd "$BELVE_WORKDIR" 2>/dev/null || true
fi

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

# --- tmux holder (experiment branch: tmux-persist-experiment) -----------------
# シェルを直接起動する代わりに tmux セッションの中で起動する。狙い:
#  (1) belve-persist broker を再起動してもシェル/実行中プロセスが tmux server 側で
#      生き残る (永続化を tmux に委譲)。
#  (2) 外部 tmux クライアント (iOS SSH アプリ等) からも `tmux attach` で刺さり、
#      PC ↔ モバイルで作業を引き継げる。
# NOTE(phase1): tmux が無い host (最小 container 等) では従来どおりシェルを直接
#   起動する。これは replay を belve-persist 側に残している間だけの暫定 guard。
#   replay 撤去 (phase2) の前に static tmux binary を bundle 配布して全 host で
#   tmux を保証し、この `command -v` guard は撤去する。
if command -v tmux >/dev/null 2>&1 && [ -z "$TMUX" ] && [ -n "$BELVE_PANE_ID" ]; then
    cat > "$HOME/.belve/belve-tmux.conf" <<'TMUXCONF'
# Belve holder config — 透過的な永続化レイヤ。
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"  # truecolor 透過 (外側 TERM=xterm-256color)
set -g allow-passthrough on                       # アプリ OSC (agent 通知/画像) 透過
set -g set-clipboard on                           # OSC52 コピー
set -g escape-time 0                              # TUI の ESC 遅延なし
set -g focus-events on
set -g history-limit 100000
set -g mouse on
set -g status off                                 # ステータスバー非表示 (Belve が UI を持つ)
set -g destroy-unattached off                     # detach してもセッション維持
set -g exit-empty off
# prefix は C-Space。C-b は readline と衝突するので回避しつつ、既定キーバインドは
# 残す。狙いは外部クライアント (mosh + tmux attach) が detach(prefix d) や
# copy-mode/scrollback(prefix [) を使えること。Belve pane 側は C-Space をほぼ
# 使わないので実害は小さい。
set -g prefix C-Space
unbind C-b
bind C-Space send-prefix
TMUXCONF
    _belve_sess="belve-$(printf '%s' "$BELVE_PANE_ID" | tr './:@ ' '_____')"
    # -A: 既存なら attach / 無ければ作成。作成時のみ pane command として $0 を
    # 再実行し、$TMUX が立った状態で下の通常シェル起動に落ちる。
    exec tmux -f "$HOME/.belve/belve-tmux.conf" new-session -A -s "$_belve_sess" "$0"
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
    [ -f ./.env ] && _m=$(stat -c %Y ./.env 2>/dev/null || stat -f %m ./.env 2>/dev/null)
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
    [ -f ./.env ] && _m=$(stat -c %Y ./.env 2>/dev/null || stat -f %m ./.env 2>/dev/null)
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
