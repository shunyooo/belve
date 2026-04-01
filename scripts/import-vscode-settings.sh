#!/usr/bin/env bash
#
# Import VS Code settings and extensions into dock-code.
# Usage: ./scripts/import-vscode-settings.sh [--extensions-only | --settings-only]
#

set -euo pipefail

VSCODE_USER_DIR="$HOME/Library/Application Support/Code/User"
VSCODE_EXT_DIR="$HOME/.vscode/extensions"

DOCKCODE_USER_DIR="$HOME/Library/Application Support/code-oss-dev/User"
DOCKCODE_EXT_DIR="$HOME/.dock-code-dev/extensions"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

do_settings=true
do_extensions=true

case "${1:-}" in
	--extensions-only) do_settings=false ;;
	--settings-only)   do_extensions=false ;;
	--help|-h)
		echo "Usage: $0 [--extensions-only | --settings-only]"
		echo ""
		echo "Copies VS Code settings and/or extensions into dock-code."
		echo "Existing dock-code settings will be backed up before overwriting."
		exit 0
		;;
esac

# --- Settings ---
if $do_settings; then
	if [ ! -d "$VSCODE_USER_DIR" ]; then
		echo -e "${RED}VS Code User directory not found:${NC} $VSCODE_USER_DIR"
		echo "Skipping settings import."
	else
		echo -e "${YELLOW}Importing settings...${NC}"
		mkdir -p "$DOCKCODE_USER_DIR"

		for file in settings.json keybindings.json; do
			src="$VSCODE_USER_DIR/$file"
			dst="$DOCKCODE_USER_DIR/$file"
			if [ -f "$src" ]; then
				if [ -f "$dst" ]; then
					cp "$dst" "$dst.bak"
					echo "  Backed up existing $file → $file.bak"
				fi
				cp "$src" "$dst"
				echo -e "  ${GREEN}✔${NC} $file"
			fi
		done

		# Copy snippets
		if [ -d "$VSCODE_USER_DIR/snippets" ]; then
			mkdir -p "$DOCKCODE_USER_DIR/snippets"
			cp -R "$VSCODE_USER_DIR/snippets/"* "$DOCKCODE_USER_DIR/snippets/" 2>/dev/null || true
			echo -e "  ${GREEN}✔${NC} snippets/"
		fi

		echo -e "${GREEN}Settings imported.${NC}"
	fi
fi

# --- Extensions ---
if $do_extensions; then
	if [ ! -d "$VSCODE_EXT_DIR" ]; then
		echo -e "${RED}VS Code extensions directory not found:${NC} $VSCODE_EXT_DIR"
		echo "Skipping extensions import."
	else
		echo -e "${YELLOW}Importing extensions...${NC}"
		mkdir -p "$DOCKCODE_EXT_DIR"

		# Extensions that are incompatible with VS Code forks (VSDA check, Microsoft-only APIs)
		BLOCKED_PREFIXES=(
			"ms-vscode-remote.remote-containers"
			"ms-vscode-remote.remote-ssh"
			"ms-vscode-remote.remote-ssh-edit"
			"ms-vscode-remote.remote-wsl"
			"ms-vscode-remote.vscode-remote-extensionpack"
			"ms-vscode.remote-explorer"
			"ms-vscode.remote-server"
		)

		count=0
		skipped=0
		for ext_dir in "$VSCODE_EXT_DIR"/*/; do
			ext_name=$(basename "$ext_dir")
			# Skip .obsolete marker and hidden files
			if [[ "$ext_name" == .* ]]; then
				continue
			fi
			# Skip blocked extensions
			blocked=false
			for prefix in "${BLOCKED_PREFIXES[@]}"; do
				if [[ "$ext_name" == "$prefix"* ]]; then
					blocked=true
					break
				fi
			done
			if $blocked; then
				skipped=$((skipped + 1))
				continue
			fi
			dst="$DOCKCODE_EXT_DIR/$ext_name"
			if [ ! -d "$dst" ]; then
				cp -R "$ext_dir" "$dst"
				count=$((count + 1))
			fi
		done
		if [ "$skipped" -gt 0 ]; then
			echo -e "  ${YELLOW}Skipped $skipped incompatible extensions (Microsoft Remote, etc.)${NC}"
		fi

		# Copy extensions.json if present
		if [ -f "$VSCODE_EXT_DIR/extensions.json" ]; then
			cp "$VSCODE_EXT_DIR/extensions.json" "$DOCKCODE_EXT_DIR/extensions.json"
		fi

		echo -e "${GREEN}✔ $count new extensions imported.${NC}"

		total=$(ls -d "$DOCKCODE_EXT_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ')
		echo "  Total extensions in dock-code: $total"
	fi
fi

echo ""
echo "Done. Restart dock-code to apply changes."
