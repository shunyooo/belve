import SwiftUI

/// Resolves SF Symbol + tint color for a file-tree entry, roughly matching
/// the vscode-icons palette/coverage within the SF Symbols budget.
///
/// Priority:
///   1. Exact filename (README.md, Dockerfile, package.json, ...)
///   2. Special folder name (.git, node_modules, src, tests, ...)
///   3. File extension (swift, ts, py, ...)
///   4. Fallback (generic file/folder)
enum FileIconResolver {
	struct Icon {
		let symbol: String
		let color: Color
	}

	// MARK: Palette
	// Colors picked to echo the vscode-icons/Material Icon Theme defaults.

	private static let swiftC = Color(red: 0.97, green: 0.47, blue: 0.27)
	private static let tsC = Color(red: 0.24, green: 0.56, blue: 0.88)
	private static let jsC = Color(red: 0.96, green: 0.82, blue: 0.31)
	private static let pyC = Color(red: 0.30, green: 0.58, blue: 0.84)
	private static let goC = Color(red: 0.00, green: 0.68, blue: 0.74)
	private static let rustC = Color(red: 0.85, green: 0.55, blue: 0.25)
	private static let rubyC = Color(red: 0.80, green: 0.17, blue: 0.20)
	private static let javaC = Color(red: 0.80, green: 0.40, blue: 0.25)
	private static let cppC = Color(red: 0.40, green: 0.55, blue: 0.85)
	private static let htmlC = Color(red: 0.90, green: 0.45, blue: 0.30)
	private static let cssC = Color(red: 0.33, green: 0.55, blue: 0.82)
	private static let jsonC = Color(red: 0.95, green: 0.75, blue: 0.20)
	private static let yamlC = Color(red: 0.80, green: 0.35, blue: 0.35)
	private static let mdC = Color(red: 0.55, green: 0.75, blue: 0.90)
	private static let shellC = Color(red: 0.50, green: 0.75, blue: 0.50)
	private static let dockerC = Color(red: 0.20, green: 0.55, blue: 0.87)
	private static let gitC = Color(red: 0.93, green: 0.38, blue: 0.27)
	private static let configC = Color(red: 0.65, green: 0.65, blue: 0.70)
	private static let lockC = Color(red: 0.55, green: 0.55, blue: 0.60)
	private static let imgC = Color(red: 0.55, green: 0.85, blue: 0.50)
	private static let videoC = Color(red: 0.85, green: 0.55, blue: 0.85)
	private static let audioC = Color(red: 0.85, green: 0.70, blue: 0.40)
	private static let pdfC = Color(red: 0.90, green: 0.35, blue: 0.30)
	private static let zipC = Color(red: 0.70, green: 0.55, blue: 0.35)
	private static let folderC = Color(red: 0.85, green: 0.70, blue: 0.30)
	private static let folderSpecialC = Color(red: 0.55, green: 0.75, blue: 0.90)
	private static let fileC = Color(white: 0.60)

	// MARK: Entry points

	static func resolve(name: String, isDirectory: Bool) -> Icon {
		if isDirectory {
			return folderIcon(name: name)
		}
		return fileIconFor(name: name)
	}

	// MARK: Folder resolution

	private static let folderMap: [String: (String, Color)] = [
		".git":           ("point.3.filled.connected.trianglepath.dotted", gitC),
		".github":        ("point.3.filled.connected.trianglepath.dotted", gitC),
		".vscode":        ("gear.badge",            folderSpecialC),
		".devcontainer":  ("shippingbox.fill",      dockerC),
		".claude":        ("brain.head.profile",    folderSpecialC),
		".serena":        ("brain.head.profile",    folderSpecialC),
		".ruff_cache":    ("archivebox.fill",       lockC),
		".pytest_cache":  ("archivebox.fill",       lockC),
		".mypy_cache":    ("archivebox.fill",       lockC),
		".ztile":         ("square.grid.2x2.fill",  folderSpecialC),
		".playwright-reports": ("theatermasks.fill", folderSpecialC),
		".review":        ("checkmark.circle.fill", green),
		"node_modules":   ("shippingbox.fill",      lockC),
		"__pycache__":    ("archivebox.fill",       lockC),
		"venv":           ("leaf.fill",             pyC),
		".venv":          ("leaf.fill",             pyC),
		".next":          ("bolt.fill",             tsC),
		"dist":           ("shippingbox.fill",      lockC),
		"build":          ("hammer.fill",           folderSpecialC),
		"target":         ("hammer.fill",           rustC),
		".build":         ("hammer.fill",           swiftC),
		"src":            ("chevron.left.slash.chevron.right", folderSpecialC),
		"lib":            ("books.vertical.fill",   folderSpecialC),
		"libs":           ("books.vertical.fill",   folderSpecialC),
		"app":            ("app.fill",              folderSpecialC),
		"apps":           ("app.fill",              folderSpecialC),
		"docs":           ("book.closed.fill",      mdC),
		"doc":            ("book.closed.fill",      mdC),
		"test":           ("checkmark.seal.fill",   green),
		"tests":          ("checkmark.seal.fill",   green),
		"__tests__":      ("checkmark.seal.fill",   green),
		"scripts":        ("terminal.fill",         shellC),
		"script":         ("terminal.fill",         shellC),
		"assets":         ("photo.fill",            imgC),
		"images":         ("photo.fill",            imgC),
		"img":            ("photo.fill",            imgC),
		"public":         ("globe",                 folderSpecialC),
		"static":         ("globe",                 folderSpecialC),
		"config":         ("gearshape.fill",        configC),
		"configs":        ("gearshape.fill",        configC),
		"terraform":      ("globe.americas.fill",   Color(red: 0.48, green: 0.35, blue: 0.82)),
		"tools":          ("wrench.and.screwdriver.fill", folderSpecialC),
		"utils":          ("wrench.adjustable",     folderSpecialC),
		"components":     ("square.stack.3d.up.fill", folderSpecialC),
		"pages":          ("doc.on.doc.fill",       folderSpecialC),
		"api":            ("network",               folderSpecialC),
		"services":       ("network",               folderSpecialC),
		"hooks":          ("link",                  folderSpecialC),
		"stdout":         ("text.alignleft",        lockC),
		"recordings":     ("record.circle.fill",    videoC),
		"screenshots":    ("camera.viewfinder",     imgC),
		"tmp":            ("archivebox",            lockC),
		"temp":           ("archivebox",            lockC),
		"creds":          ("key.fill",              Color(red: 0.90, green: 0.70, blue: 0.25)),
		"secrets":        ("key.fill",              Color(red: 0.90, green: 0.70, blue: 0.25)),
	]

	private static let green = Color(red: 0.35, green: 0.75, blue: 0.45)

	private static func folderIcon(name: String) -> Icon {
		if let (symbol, color) = folderMap[name.lowercased()] {
			return Icon(symbol: symbol, color: color)
		}
		// dot-folder: fade but keep folder shape
		if name.hasPrefix(".") {
			return Icon(symbol: "folder.fill", color: folderC.opacity(0.6))
		}
		return Icon(symbol: "folder.fill", color: folderC)
	}

	// MARK: File resolution

	private static let filenameMap: [String: (String, Color)] = [
		"readme.md":           ("text.book.closed.fill", mdC),
		"readme":              ("text.book.closed.fill", mdC),
		"license":             ("doc.text.fill", configC),
		"license.md":          ("doc.text.fill", configC),
		"license.txt":         ("doc.text.fill", configC),
		"changelog.md":        ("clock.arrow.circlepath", mdC),
		"changelog":           ("clock.arrow.circlepath", mdC),
		"claude.md":           ("brain.head.profile", folderSpecialC),

		"dockerfile":          ("shippingbox.fill", dockerC),
		"dockerfile.dev":      ("shippingbox.fill", dockerC),
		"docker-compose.yml":  ("shippingbox.fill", dockerC),
		"docker-compose.yaml": ("shippingbox.fill", dockerC),
		".dockerignore":       ("shippingbox", dockerC),

		"makefile":            ("hammer.fill", folderSpecialC),
		"cmakelists.txt":      ("hammer.fill", folderSpecialC),

		"package.json":        ("shippingbox.fill", jsC),
		"package-lock.json":   ("lock.fill", lockC),
		"yarn.lock":           ("lock.fill", lockC),
		"pnpm-lock.yaml":      ("lock.fill", lockC),
		"bun.lockb":           ("lock.fill", lockC),
		"composer.json":       ("shippingbox.fill", Color(red: 0.45, green: 0.40, blue: 0.70)),
		"composer.lock":       ("lock.fill", lockC),
		"gemfile":             ("shippingbox.fill", rubyC),
		"gemfile.lock":        ("lock.fill", rubyC),
		"cargo.toml":          ("shippingbox.fill", rustC),
		"cargo.lock":          ("lock.fill", rustC),
		"go.mod":              ("shippingbox.fill", goC),
		"go.sum":              ("lock.fill", goC),
		"pyproject.toml":      ("shippingbox.fill", pyC),
		"poetry.lock":         ("lock.fill", pyC),
		"uv.lock":             ("lock.fill", pyC),
		"requirements.txt":    ("list.bullet.rectangle.fill", pyC),
		"pipfile":             ("shippingbox.fill", pyC),
		"pipfile.lock":        ("lock.fill", pyC),
		"package.swift":       ("shippingbox.fill", swiftC),

		".gitignore":          ("eye.slash.fill", gitC),
		".gitattributes":      ("gearshape.fill", gitC),
		".gcloudignore":       ("eye.slash.fill", configC),

		".env":                ("key.horizontal.fill", Color(red: 0.95, green: 0.80, blue: 0.25)),
		".env.example":        ("key.horizontal",       Color(red: 0.95, green: 0.80, blue: 0.25)),
		".env.local":          ("key.horizontal.fill", Color(red: 0.95, green: 0.80, blue: 0.25)),
		".env.production":     ("key.horizontal.fill", Color(red: 0.95, green: 0.80, blue: 0.25)),

		".editorconfig":       ("gearshape.fill", configC),
		".eslintrc":           ("checkmark.shield.fill", Color(red: 0.43, green: 0.37, blue: 0.73)),
		".eslintrc.json":      ("checkmark.shield.fill", Color(red: 0.43, green: 0.37, blue: 0.73)),
		".prettierrc":         ("paintpalette.fill", Color(red: 0.95, green: 0.50, blue: 0.65)),
		".prettierrc.json":    ("paintpalette.fill", Color(red: 0.95, green: 0.50, blue: 0.65)),
		".pre-commit-config.yaml": ("checkmark.shield.fill", yamlC),
		".python-version":     ("number", pyC),
		".node-version":       ("number", jsC),
		".nvmrc":              ("number", jsC),
		".ruby-version":       ("number", rubyC),

		"tsconfig.json":       ("gearshape.fill", tsC),
		"tsconfig.base.json":  ("gearshape.fill", tsC),
		"jsconfig.json":       ("gearshape.fill", jsC),
		"vite.config.ts":      ("bolt.fill", tsC),
		"vite.config.js":      ("bolt.fill", jsC),
		"next.config.js":      ("bolt.fill", jsC),
		"next.config.ts":      ("bolt.fill", tsC),
		"tailwind.config.js":  ("wind", Color(red: 0.24, green: 0.70, blue: 0.86)),
		"tailwind.config.ts":  ("wind", Color(red: 0.24, green: 0.70, blue: 0.86)),

		".mcp.json":           ("network", folderSpecialC),
		"mcp.json":            ("network", folderSpecialC),
	]

	private static let extensionMap: [String: (String, Color)] = [
		// Languages
		"swift":     ("swift", swiftC),
		"ts":        ("chevron.left.forwardslash.chevron.right", tsC),
		"tsx":       ("atom", tsC),
		"js":        ("chevron.left.forwardslash.chevron.right", jsC),
		"jsx":       ("atom", jsC),
		"mjs":       ("chevron.left.forwardslash.chevron.right", jsC),
		"cjs":       ("chevron.left.forwardslash.chevron.right", jsC),
		"py":        ("chevron.left.forwardslash.chevron.right", pyC),
		"pyi":       ("chevron.left.forwardslash.chevron.right", pyC),
		"go":        ("chevron.left.forwardslash.chevron.right", goC),
		"rs":        ("chevron.left.forwardslash.chevron.right", rustC),
		"rb":        ("chevron.left.forwardslash.chevron.right", rubyC),
		"java":      ("cup.and.saucer.fill", javaC),
		"kt":        ("chevron.left.forwardslash.chevron.right", Color(red: 0.52, green: 0.40, blue: 0.85)),
		"kts":      ("chevron.left.forwardslash.chevron.right", Color(red: 0.52, green: 0.40, blue: 0.85)),
		"scala":     ("chevron.left.forwardslash.chevron.right", Color(red: 0.85, green: 0.30, blue: 0.30)),
		"c":         ("chevron.left.forwardslash.chevron.right", cppC),
		"h":         ("chevron.left.forwardslash.chevron.right", cppC),
		"cpp":       ("chevron.left.forwardslash.chevron.right", cppC),
		"cc":        ("chevron.left.forwardslash.chevron.right", cppC),
		"hpp":       ("chevron.left.forwardslash.chevron.right", cppC),
		"cs":        ("chevron.left.forwardslash.chevron.right", Color(red: 0.40, green: 0.35, blue: 0.80)),
		"php":       ("chevron.left.forwardslash.chevron.right", Color(red: 0.48, green: 0.45, blue: 0.75)),
		"lua":       ("chevron.left.forwardslash.chevron.right", Color(red: 0.20, green: 0.25, blue: 0.75)),
		"dart":      ("chevron.left.forwardslash.chevron.right", Color(red: 0.10, green: 0.60, blue: 0.80)),
		"zig":       ("chevron.left.forwardslash.chevron.right", Color(red: 0.95, green: 0.55, blue: 0.15)),

		// Web
		"html":      ("globe", htmlC),
		"htm":       ("globe", htmlC),
		"css":       ("paintbrush.fill", cssC),
		"scss":      ("paintbrush.fill", Color(red: 0.80, green: 0.40, blue: 0.55)),
		"sass":      ("paintbrush.fill", Color(red: 0.80, green: 0.40, blue: 0.55)),
		"less":      ("paintbrush.fill", Color(red: 0.20, green: 0.30, blue: 0.60)),
		"vue":       ("chevron.left.forwardslash.chevron.right", Color(red: 0.26, green: 0.72, blue: 0.50)),
		"svelte":    ("chevron.left.forwardslash.chevron.right", Color(red: 0.95, green: 0.42, blue: 0.27)),
		"astro":     ("chevron.left.forwardslash.chevron.right", Color(red: 0.55, green: 0.30, blue: 0.90)),

		// Data / config
		"json":      ("curlybraces",       jsonC),
		"jsonc":     ("curlybraces",       jsonC),
		"json5":     ("curlybraces",       jsonC),
		"yml":       ("list.bullet.indent", yamlC),
		"yaml":      ("list.bullet.indent", yamlC),
		"toml":      ("list.bullet.indent", Color(red: 0.60, green: 0.35, blue: 0.35)),
		"ini":       ("list.bullet.indent", configC),
		"xml":       ("chevron.left.forwardslash.chevron.right", Color(red: 0.85, green: 0.55, blue: 0.40)),
		"plist":     ("list.bullet.indent", configC),
		"env":       ("key.horizontal.fill", Color(red: 0.95, green: 0.80, blue: 0.25)),

		// Docs
		"md":        ("doc.richtext.fill", mdC),
		"mdx":       ("doc.richtext.fill", mdC),
		"rst":       ("doc.richtext",       mdC),
		"txt":       ("doc.text",           fileC),
		"pdf":       ("doc.fill",           pdfC),

		// Shell / build
		"sh":        ("terminal.fill",      shellC),
		"bash":      ("terminal.fill",      shellC),
		"zsh":       ("terminal.fill",      shellC),
		"fish":      ("terminal.fill",      shellC),
		"ps1":       ("terminal.fill",      Color(red: 0.20, green: 0.45, blue: 0.80)),

		// Images
		"png":       ("photo.fill",         imgC),
		"jpg":       ("photo.fill",         imgC),
		"jpeg":      ("photo.fill",         imgC),
		"gif":       ("photo.fill",         imgC),
		"webp":      ("photo.fill",         imgC),
		"bmp":       ("photo.fill",         imgC),
		"svg":       ("scribble.variable",  imgC),
		"ico":       ("photo.fill",         imgC),

		// Video
		"mp4":       ("film.fill",          videoC),
		"mov":       ("film.fill",          videoC),
		"webm":      ("film.fill",          videoC),
		"avi":       ("film.fill",          videoC),
		"mkv":       ("film.fill",          videoC),

		// Audio
		"mp3":       ("waveform",           audioC),
		"wav":       ("waveform",           audioC),
		"flac":      ("waveform",           audioC),
		"ogg":       ("waveform",           audioC),
		"m4a":       ("waveform",           audioC),

		// Archives
		"zip":       ("archivebox.fill",    zipC),
		"tar":       ("archivebox.fill",    zipC),
		"gz":        ("archivebox.fill",    zipC),
		"bz2":       ("archivebox.fill",    zipC),
		"7z":        ("archivebox.fill",    zipC),
		"rar":       ("archivebox.fill",    zipC),

		// Database / data
		"sql":       ("cylinder.split.1x2.fill", Color(red: 0.30, green: 0.50, blue: 0.85)),
		"sqlite":    ("cylinder.fill",           Color(red: 0.30, green: 0.50, blue: 0.85)),
		"db":        ("cylinder.fill",           Color(red: 0.30, green: 0.50, blue: 0.85)),
		"csv":       ("tablecells.fill",         Color(red: 0.35, green: 0.70, blue: 0.40)),
		"tsv":       ("tablecells.fill",         Color(red: 0.35, green: 0.70, blue: 0.40)),
		"parquet":   ("cylinder.fill",           Color(red: 0.30, green: 0.50, blue: 0.85)),

		// Fonts
		"ttf":       ("textformat",              folderSpecialC),
		"otf":       ("textformat",              folderSpecialC),
		"woff":      ("textformat",              folderSpecialC),
		"woff2":     ("textformat",              folderSpecialC),

		// Infra
		"tf":        ("globe.americas.fill",     Color(red: 0.48, green: 0.35, blue: 0.82)),
		"tfvars":    ("globe.americas.fill",     Color(red: 0.48, green: 0.35, blue: 0.82)),
		"nix":       ("snowflake",               Color(red: 0.30, green: 0.55, blue: 0.85)),

		// Notebooks
		"ipynb":     ("book.pages.fill",         Color(red: 0.95, green: 0.55, blue: 0.20)),

		// Logs
		"log":       ("text.alignleft",          fileC),
	]

	// MARK: Public helper view

	// (see FileTypeIconView at bottom of this file)

	private static func fileIconFor(name: String) -> Icon {
		let lower = name.lowercased()
		if let (symbol, color) = filenameMap[lower] {
			return Icon(symbol: symbol, color: color)
		}
		// "Dockerfile.prod" etc. — match by "dockerfile" prefix
		if lower.hasPrefix("dockerfile") {
			return Icon(symbol: "shippingbox.fill", color: dockerC)
		}
		if lower.hasPrefix("makefile") {
			return Icon(symbol: "hammer.fill", color: folderSpecialC)
		}
		let ext = (name as NSString).pathExtension.lowercased()
		if !ext.isEmpty, let (symbol, color) = extensionMap[ext] {
			return Icon(symbol: symbol, color: color)
		}
		// Dot-file fallback (no match above)
		if name.hasPrefix(".") {
			return Icon(symbol: "doc", color: fileC.opacity(0.8))
		}
		return Icon(symbol: "doc", color: fileC)
	}
}

/// Thin view wrapper that resolves the icon once per render.
struct FileTypeIconView: View {
	let name: String
	let isDirectory: Bool

	var body: some View {
		let icon = FileIconResolver.resolve(name: name, isDirectory: isDirectory)
		Image(systemName: icon.symbol)
			.font(.system(size: 11))
			.foregroundStyle(icon.color)
	}
}
