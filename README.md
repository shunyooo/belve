# Belve

A native macOS (Swift / SwiftUI) multi-project development environment.
Belve bundles multiple projects in a single window and lets you work across SSH / DevContainer / local targets — **terminal, code editor, file tree, and Markdown WYSIWYG** in one app.

## Features

- **Multi-project** — Switch between projects from the sidebar; each project keeps its own terminals, editor state, and file tree.
- **Remote-first** — SSH hosts, DevContainers, and local folders share the same UI. SSH traffic is multiplexed over a single ControlMaster session with dynamic port forwards, so `MaxSessions` is never exhausted.
- **Session persistence** — `belve-persist` (Go) holds the PTY on the remote side. Restart the app or drop the connection and your terminal sessions come back.
- **Fast terminal** — xterm.js in WKWebView with ANSI colors, link detection, pane splits, and smooth resize.
- **Code editor** — CodeMirror 6 in WKWebView: syntax highlighting, diff gutter, file search.
- **Markdown WYSIWYG** — Milkdown Crepe for inline `.md` editing.
- **Agent session tracking** — Captures every Claude Code / Codex hook event and surfaces real-time agent status in the sidebar.
- **Native** — No Electron. One window, one process. macOS 14+ only.

## Build

```bash
# First-time setup
npm install

# Build the .app bundle
./scripts/build-app.sh

# Launch (always via the .app bundle — running the raw binary prevents macOS from
# recognizing it as an app and keyboard events are lost)
open Belve.app
```

Clean build when Swift Package Manager caches act up:

```bash
swift package clean && ./scripts/build-app.sh
```

## Documentation

- [CLAUDE.md](CLAUDE.md) — Project guide (build, test, conventions)
- [docs/architecture.md](docs/architecture.md) — Architecture overview
- [docs/DESIGN.md](docs/DESIGN.md) — Design principles
- [docs/development-guide.md](docs/development-guide.md) — Developer workflow

## Stack

- SwiftUI (macOS 14+)
- xterm.js / CodeMirror 6 / Milkdown (WKWebView)
- Go (`belve-persist` — dtach-like PTY persistence)
- System `ssh` + `devcontainer` CLI

## Versioning

- **v1.x** — Archived era when Belve was a VS Code (Electron) fork.
- **v2.0+** — Current native Swift implementation, rewritten from scratch.

## License

See [LICENSE](LICENSE).
