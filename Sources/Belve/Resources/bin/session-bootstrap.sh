#!/bin/sh
# session-bootstrap.sh: shell initialization for Belve sessions
# Environment expected: BELVE_SESSION, BELVE_PROJECT_ID, BELVE_PANE_INDEX, BELVE_PANE_ID
# These are inherited from the caller (belve-connect or docker exec -e)

export BELVE_SESSION="${BELVE_SESSION:-1}"
export PATH="$HOME/.belve/bin:$PATH"

SHELL_PATH="${SHELL:-/bin/bash}"
SHELL_NAME="$(basename "$SHELL_PATH")"

case "$SHELL_NAME" in
  bash)
    cat > "$HOME/.belve/belve-bashrc" <<'BASHRC'
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile"
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
export PATH="$HOME/.belve/bin:$PATH"
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
ZSHRC
    exec env ZDOTDIR="$HOME/.belve/zdotdir" "$SHELL_PATH" -l -i ;;
  fish)
    exec "$SHELL_PATH" --init-command 'set -gx PATH "$HOME/.belve/bin" $PATH' ;;
  *)
    exec env PATH="$HOME/.belve/bin:$PATH" "$SHELL_PATH" -l -i ;;
esac
