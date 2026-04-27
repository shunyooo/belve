// Belve Markdown preview (read-only). marked.js で md → HTML レンダリング、
// `code.language-mermaid` の中身は mermaid.js で SVG に置換。
// 編集機能は持たない (= 編集したい時は Cmd+E 等で CodeMirror に切り替える)。
import { marked } from "marked";
import mermaid from "mermaid";

marked.setOptions({
	gfm: true,        // GitHub Flavored Markdown
	breaks: true,     // 単一改行を <br> に
});

// Mermaid: 起動時に 1 回だけ初期化。startOnLoad=false で自分で発火 (= preview
// renderer の都度呼び出しに合わせる)。テーマは host HTML の dark/light に従う。
mermaid.initialize({
	startOnLoad: false,
	securityLevel: "loose",  // file: 経由なので script-src strict にする必要なし
	theme: detectMermaidTheme(),
	fontFamily: "ui-sans-serif, -apple-system, BlinkMacSystemFont, sans-serif",
});

function detectMermaidTheme() {
	// host CSS が prefers-color-scheme か `data-theme` 属性で dark を示してれば dark。
	const root = document.documentElement;
	if (root.dataset.theme === "dark") return "dark";
	if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) return "dark";
	return "default";
}

const root = document.getElementById("preview");

// Mermaid render は async。各 markdownRender の世代を区別する token を持って、
// 古い render の SVG が新 render の DOM を上書きするのを防ぐ。
let renderToken = 0;

window.markdownRender = function (md) {
	const myToken = ++renderToken;
	root.innerHTML = marked.parse(md || "");
	renderMermaidBlocks(myToken).catch((err) => {
		console.warn("[belve-md] mermaid render failed:", err);
	});
};

async function renderMermaidBlocks(token) {
	// marked は ```mermaid を `<pre><code class="language-mermaid">...</code></pre>`
	// に変換する。それを SVG に置換する。
	const blocks = Array.from(root.querySelectorAll("pre > code.language-mermaid"));
	if (blocks.length === 0) return;
	let i = 0;
	for (const code of blocks) {
		if (token !== renderToken) return;  // newer render in flight; abort
		const source = code.textContent || "";
		const id = `belve-mermaid-${Date.now()}-${i++}`;
		try {
			const { svg } = await mermaid.render(id, source);
			if (token !== renderToken) return;
			const wrapper = document.createElement("div");
			wrapper.className = "belve-mermaid";
			wrapper.innerHTML = svg;
			code.parentElement.replaceWith(wrapper);
		} catch (err) {
			if (token !== renderToken) return;
			const errBox = document.createElement("pre");
			errBox.className = "belve-mermaid-error";
			errBox.textContent = `Mermaid render error:\n${(err && err.message) || String(err)}\n\n${source}`;
			code.parentElement.replaceWith(errBox);
		}
	}
}

// 外部リンクは新規タブで開く (= Belve 側で openUrl handle)
document.addEventListener("click", function (e) {
	const a = e.target.closest("a");
	if (!a) return;
	const href = a.getAttribute("href");
	if (!href) return;
	e.preventDefault();
	window.webkit.messageHandlers.markdownPreviewHandler.postMessage({
		type: "openUrl",
		url: href,
	});
});

window.webkit.messageHandlers.markdownPreviewHandler.postMessage({ type: "ready" });
