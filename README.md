<p align="center">
  <h1 align="center">Belve</h1>
  <p align="center">
    A native macOS workspace for multi-project SSH &amp; DevContainer development
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black.svg" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-5.9-orange.svg" alt="Swift 5.9">
    <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT">
  </p>
  <p align="center">
    <a href="#features">Features</a> · <a href="#install">Install</a> · <a href="#stack">Stack</a> · <a href="#docs">Docs</a>
  </p>
</p>

---

Belve is a single-window, native macOS app that brings **terminal, code editor, file tree, and Markdown WYSIWYG** together — across local, SSH, and DevContainer targets. Built in Swift / SwiftUI from the ground up. No Electron. One process.

## Features

- 🧱 **Multi-project sidebar** — Independent state per project, smooth cross-project switching (`Cmd+[` / `Cmd+]`).
- 🔗 **Unified remote UX** — SSH / DevContainer / local folders, same interface.
- 🪢 **Single SSH connection, many panes** — ControlMaster + port forward multiplexing. No more `Session open refused`.
- 🧷 **Persistent sessions** — `belve-persist` holds PTYs across reconnects and app restarts.
- ⚡ **Fast terminal** — xterm.js in WKWebView. Pane splits, ANSI, link detection, scrollback.
- 📝 **Integrated editor** — CodeMirror 6 with syntax highlighting, diff gutter, file search.
- 🎨 **Markdown WYSIWYG** — Milkdown Crepe for inline `.md` editing.
- 🤖 **Agent session bar** — Claude Code / Codex hooks tracked live with tool, status, and activity per pane.

## Install

Download the latest `Belve-vX.Y.Z.dmg` from the [Releases](https://github.com/shunyooo/belve/releases) page, open it, and drag `Belve.app` into `Applications`.

Because Belve is ad-hoc signed (no paid Apple Developer ID yet), the first launch needs a one-time Gatekeeper confirmation:

```bash
# Option A — right-click Belve.app → Open → "Open" in the warning dialog
# Option B — strip the quarantine attribute
xattr -cr /Applications/Belve.app
```

Subsequent launches open normally. Requires macOS 14+.

### Build from source

```bash
# Prerequisites: Xcode 15+, Node 20+, Go 1.21+
git clone https://github.com/shunyooo/belve.git
cd belve
npm install
./scripts/build-app.sh
open Belve.app
```

> **Important** — always launch via the `.app` bundle. Running the raw Swift binary prevents macOS from treating it as an app, which breaks keyboard input.

Clean build if SPM caches get stuck:

```bash
swift package clean && ./scripts/build-app.sh
```

## Stack

| Layer            | Technology                                       |
| ---------------- | ------------------------------------------------ |
| App shell        | Swift / SwiftUI (macOS 14+)                      |
| Terminal         | xterm.js (WKWebView) + PTY via `posix_spawn`     |
| Editor           | CodeMirror 6 (WKWebView)                         |
| Markdown         | Milkdown Crepe (WKWebView)                       |
| Session persist  | `belve-persist` — Go, dtach-like                 |
| Remote transport | System `ssh` (ControlMaster + port forward)      |
| DevContainer     | `devcontainer` CLI                               |

## Docs

- [CLAUDE.md](CLAUDE.md) — project guide (build, test, conventions)
- [docs/architecture.md](docs/architecture.md) — architecture overview
- [docs/development-guide.md](docs/development-guide.md) — developer workflow
- [docs/todo.md](docs/todo.md) — roadmap
- [docs/notes/](docs/notes/) — dated notes and design memos

## Versioning

- **v1.x** — Archived era when Belve was a VS Code (Electron) fork.
- **v2.0+** — Current Swift native implementation, rewritten from scratch.

## License

See [LICENSE](LICENSE).
