# dock-code

A desktop app for managing multiple development environments (SSH / DevContainer) in a single window with instant switching. Built on VS Code.

```
┌─────────────────────────────────────────────────────────────┐
│ [P1] [P2] [P3] │  Terminal  │  VS Code Editor              │
│                 │            │                              │
│  ProjectBar     │  Pane      │  ActivityBar + Sidebar +     │
│  (project       │  Container │  Editor + Panel              │
│   switching)    │            │                              │
│                 │────────────│                              │
│                 │  Terminal  │                              │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **Multi-Project** — Manage multiple projects in a single window. Each project has its own Extension Host and remote connection
- **SSH Remote Development** — Custom SSH resolver (no VSDA dependency). Edit files and run terminals on remote hosts within a project
- **DevContainer** — Run `devcontainer up` on SSH hosts. Seamlessly switch between SSH and DevContainer
- **PaneContainer** — Freely split terminal/pane area next to the ProjectBar
- **VS Code Compatible** — Marketplace extensions, themes, and keybindings work out of the box

## Architecture

```
Single BrowserWindow
├── Project 1 (main webContents) ── Extension Host 1 ── SSH/DevContainer A
├── Project 2 (WebContentsView)  ── Extension Host 2 ── SSH/DevContainer B
├── Project 3 (WebContentsView)  ── Extension Host 3 ── SSH/DevContainer C
└── Switching: view.setVisible(true/false) + webContents.focus()
```

Each project runs as an independent renderer process using Electron's `WebContentsView`. Switching between projects is instant via view visibility toggling.

## Development

```bash
# Install dependencies
npm ci

# Type check
npm run compile-check-ts-native

# Transpile
NODE_OPTIONS="--experimental-strip-types" node build/next/index.ts transpile

# Launch
./scripts/code.sh

# Build REH server (runs automatically via GitHub Actions)
NODE_OPTIONS="--experimental-strip-types" node --max-old-space-size=8192 \
  ./node_modules/gulp/bin/gulp.js vscode-reh-linux-x64
```

## License

[MIT](LICENSE.txt)

Fork of [microsoft/vscode](https://github.com/microsoft/vscode).
