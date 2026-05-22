// Belve Markdown preview (read-only). marked.js で md → HTML レンダリング、
// highlight.js でシンタックスハイライト、
// `code.language-mermaid` の中身は mermaid.js で SVG に置換。
// 編集機能は持たない (= 編集したい時は Cmd+E 等で CodeMirror に切り替える)。
import { marked } from "marked";
import mermaid from "mermaid";
import hljs from "highlight.js/lib/core";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import python from "highlight.js/lib/languages/python";
import bash from "highlight.js/lib/languages/bash";
import json from "highlight.js/lib/languages/json";
import yaml from "highlight.js/lib/languages/yaml";
import css from "highlight.js/lib/languages/css";
import xml from "highlight.js/lib/languages/xml";
import sql from "highlight.js/lib/languages/sql";
import go from "highlight.js/lib/languages/go";
import swift from "highlight.js/lib/languages/swift";
import rust from "highlight.js/lib/languages/rust";
import markdown from "highlight.js/lib/languages/markdown";
import diff from "highlight.js/lib/languages/diff";
import shell from "highlight.js/lib/languages/shell";
import dockerfile from "highlight.js/lib/languages/dockerfile";

hljs.registerLanguage("javascript", javascript);
hljs.registerLanguage("js", javascript);
hljs.registerLanguage("typescript", typescript);
hljs.registerLanguage("ts", typescript);
hljs.registerLanguage("python", python);
hljs.registerLanguage("bash", bash);
hljs.registerLanguage("sh", bash);
hljs.registerLanguage("zsh", bash);
hljs.registerLanguage("json", json);
hljs.registerLanguage("yaml", yaml);
hljs.registerLanguage("yml", yaml);
hljs.registerLanguage("css", css);
hljs.registerLanguage("html", xml);
hljs.registerLanguage("xml", xml);
hljs.registerLanguage("sql", sql);
hljs.registerLanguage("go", go);
hljs.registerLanguage("swift", swift);
hljs.registerLanguage("rust", rust);
hljs.registerLanguage("markdown", markdown);
hljs.registerLanguage("md", markdown);
hljs.registerLanguage("diff", diff);
hljs.registerLanguage("shell", shell);
hljs.registerLanguage("dockerfile", dockerfile);

marked.setOptions({
	gfm: true,        // GitHub Flavored Markdown
	breaks: true,     // 単一改行を <br> に
});

// marked の renderer をカスタマイズして highlight.js を適用
const renderer = new marked.Renderer();
renderer.code = function({ text, lang }) {
	if (lang === "mermaid") {
		return '<pre><code class="language-mermaid">' + text + '</code></pre>';
	}
	let highlighted;
	if (lang && hljs.getLanguage(lang)) {
		highlighted = hljs.highlight(text, { language: lang }).value;
	} else {
		highlighted = hljs.highlightAuto(text).value;
	}
	const cls = lang ? ' class="language-' + lang + ' hljs"' : ' class="hljs"';
	return '<pre><code' + cls + '>' + highlighted + '</code></pre>';
};
marked.use({ renderer });

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
// 前回レンダリング時のブロック snapshot (diff 用)
let prevBlocks = [];

function snapshotBlocks(container) {
	const blocks = [];
	for (const child of container.children) {
		blocks.push({
			tag: child.tagName,
			text: child.textContent || "",
			html: child.innerHTML || "",
		});
	}
	return blocks;
}

function applyDiffHighlights(container, oldBlocks, newBlocks) {
	// LCS ベースの block diff。tag + text で identity を判定。
	const n = oldBlocks.length, m = newBlocks.length;
	// Build LCS table
	const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
	for (let i = 1; i <= n; i++) {
		for (let j = 1; j <= m; j++) {
			if (oldBlocks[i-1].tag === newBlocks[j-1].tag && oldBlocks[i-1].text === newBlocks[j-1].text) {
				dp[i][j] = dp[i-1][j-1] + 1;
			} else {
				dp[i][j] = Math.max(dp[i-1][j], dp[i][j-1]);
			}
		}
	}
	// Backtrack to find matches
	const matched = new Set(); // indices in newBlocks that are unchanged
	let i = n, j = m;
	while (i > 0 && j > 0) {
		if (oldBlocks[i-1].tag === newBlocks[j-1].tag && oldBlocks[i-1].text === newBlocks[j-1].text) {
			matched.add(j - 1);
			// Check if HTML changed (= formatting change within same text)
			if (oldBlocks[i-1].html !== newBlocks[j-1].html) {
				const el = container.children[j - 1];
				if (el) el.classList.add("belve-diff-modified");
			}
			i--; j--;
		} else if (dp[i-1][j] > dp[i][j-1]) {
			i--;
		} else {
			j--;
		}
	}

	// Find which old blocks were deleted (not in LCS)
	const oldMatched = new Set();
	i = n; j = m;
	while (i > 0 && j > 0) {
		if (oldBlocks[i-1].tag === newBlocks[j-1].tag && oldBlocks[i-1].text === newBlocks[j-1].text) {
			oldMatched.add(i - 1);
			i--; j--;
		} else if (dp[i-1][j] > dp[i][j-1]) {
			i--;
		} else {
			j--;
		}
	}

	// Build old→new index mapping via LCS backtrack.
	// oldToNew[i] = j means old block i matched new block j. -1 = deleted.
	const oldToNew = new Array(n).fill(-1);
	i = n; j = m;
	while (i > 0 && j > 0) {
		if (oldBlocks[i-1].tag === newBlocks[j-1].tag && oldBlocks[i-1].text === newBlocks[j-1].text) {
			oldToNew[i-1] = j-1;
			i--; j--;
		} else if (dp[i-1][j] > dp[i][j-1]) {
			i--;
		} else {
			j--;
		}
	}

	// Mark new blocks (added or modified)
	const children = container.children;
	for (let k = 0; k < newBlocks.length; k++) {
		if (matched.has(k)) continue;
		const el = children[k];
		if (!el) continue;
		const isModified = oldBlocks.some(ob => ob.tag === newBlocks[k].tag && ob.text !== newBlocks[k].text &&
			similarity(ob.text, newBlocks[k].text) > 0.3);
		el.classList.add(isModified ? "belve-diff-modified" : "belve-diff-added");
	}

	// Show deleted blocks as ghost elements at their approximate position.
	// Find the nearest matched neighbor to determine insertion point.
	for (let k = 0; k < n; k++) {
		if (oldToNew[k] !== -1) continue; // not deleted
		const db = oldBlocks[k];
		const ghost = document.createElement(db.tag || "p");
		ghost.className = "belve-diff-removed";
		ghost.textContent = db.text.slice(0, 200);
		// Find the next matched old block after this one to get insertion point
		let insertBefore = null;
		for (let after = k + 1; after < n; after++) {
			if (oldToNew[after] !== -1) {
				insertBefore = container.children[oldToNew[after]];
				break;
			}
		}
		if (insertBefore) {
			container.insertBefore(ghost, insertBefore);
		} else {
			container.appendChild(ghost);
		}
		ghost.addEventListener("animationend", () => ghost.remove());
	}
}

function similarity(a, b) {
	if (!a || !b) return 0;
	const shorter = a.length < b.length ? a : b;
	const longer = a.length < b.length ? b : a;
	if (longer.length === 0) return 1;
	let matches = 0;
	const words = shorter.split(/\s+/);
	for (const w of words) {
		if (w.length > 2 && longer.includes(w)) matches++;
	}
	return words.length > 0 ? matches / words.length : 0;
}

window.markdownRender = function (md) {
	const myToken = ++renderToken;
	const oldBlocks = prevBlocks;
	root.innerHTML = marked.parse(md || "");
	const newBlocks = snapshotBlocks(root);
	// Diff highlight (skip on first render)
	if (oldBlocks.length > 0) {
		applyDiffHighlights(root, oldBlocks, newBlocks);
	}
	prevBlocks = newBlocks;
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
