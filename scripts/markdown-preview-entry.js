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
function escapeHtml(s) {
	return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
renderer.code = function({ text, lang }) {
	if (lang === "mermaid") {
		// source を HTML エスケープして DOM へ。後で `code.textContent` で読み戻す
		// 設計のため、生の `<br/>` を入れると browser parse で <br> 要素に変換され
		// textContent が空文字 (改行) になり、mermaid に届く時に消えてしまう。
		// エスケープしておけば textContent で `<br/>` のまま読み戻せる。
		return '<pre><code class="language-mermaid">' + escapeHtml(text) + '</code></pre>';
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

// 画像 src を belve-img:// scheme に書き換え、Swift 側 handler が remote / local
// から bytes を取得できるようにする。http(s):/data: はそのまま (= 外部 / inline)。
// 相対パスは markdown file の dir (window.__belveMarkdownDir) 基準で絶対化する。
function resolveImagePath(src) {
	if (!src) return src;
	if (/^(https?:|data:|belve-img:)/i.test(src)) return src;
	let combined;
	if (src.startsWith("/")) {
		combined = src; // 絶対パスはそのまま
	} else {
		const base = window.__belveMarkdownDir || "";
		combined = base ? base + "/" + src : src;
	}
	// combined の絶対 / 相対を保ったまま正規化する。DevContainer は
	// effectivePath="." で file path が相対 (e.g. "docs/foo.md") なので、
	// ここで絶対化すると downloadFile の RWS 基準解決が効かず docker cp が
	// container 内で見つけられなくなる。相対は相対のまま Swift へ渡す。
	return "belve-img://x/" + encodeURIComponent(normalizePath(combined));
}
// POSIX パス正規化 (. / .. を畳む)。先頭 "/" の有無 (= 絶対/相対) は維持。
function normalizePath(p) {
	const isAbs = p.startsWith("/");
	const parts = p.split("/");
	const out = [];
	for (const seg of parts) {
		if (seg === "" || seg === ".") continue;
		if (seg === "..") { out.pop(); continue; }
		out.push(seg);
	}
	return (isAbs ? "/" : "") + out.join("/");
}
renderer.image = function({ href, title, text }) {
	const resolved = resolveImagePath(href);
	const t = title ? ' title="' + escapeHtml(title) + '"' : "";
	return '<img src="' + escapeHtml(resolved) + '" alt="' + escapeHtml(text || "") + '"' + t + '>';
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

// Scroll position 同期 (Edit ↔ Preview トグル時の位置引き継ぎ用)。
// % を連続で Swift に postMessage、Swift 側で store に書き込む。
// rAF throttle で過剰送信を抑える。
let _scrollPostScheduled = false;
function postScrollPercent() {
	const el = document.scrollingElement || document.documentElement;
	const max = el.scrollHeight - el.clientHeight;
	const pct = max > 0 ? el.scrollTop / max : 0;
	window.webkit.messageHandlers.markdownPreviewHandler.postMessage({
		type: "scroll", percent: pct,
	});
}
window.addEventListener("scroll", function() {
	if (_scrollPostScheduled) return;
	_scrollPostScheduled = true;
	requestAnimationFrame(function() {
		_scrollPostScheduled = false;
		postScrollPercent();
	});
}, { passive: true });

// Swift から呼ぶ: トグルで mount された直後に「前回の % まで scroll しろ」と指示。
window.setScrollPercent = function(pct) {
	const el = document.scrollingElement || document.documentElement;
	const max = el.scrollHeight - el.clientHeight;
	if (max <= 0) return;
	el.scrollTop = max * pct;
};

// In-page search (Cmd+F from Swift)
(function() {
	var bar = document.createElement("div");
	bar.id = "find-bar";
	bar.style.cssText = "position:fixed;bottom:0;left:0;right:0;z-index:9999;padding:6px 12px;background:rgba(30,30,46,0.96);border-top:1px solid rgba(255,255,255,0.1);backdrop-filter:blur(8px);transform:translateY(100%);opacity:0;transition:transform 0.15s ease-out,opacity 0.15s ease-out;pointer-events:none;";
	bar.innerHTML = '<input id="find-input" type="text" placeholder="Search…" style="width:240px;padding:4px 8px;font-size:13px;background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.15);border-radius:4px;color:#cdd6f4;outline:none;">'
		+ '<span id="find-count" style="margin-left:8px;font-size:11px;color:rgba(255,255,255,0.5);"></span>';
	document.body.appendChild(bar);

	var marks = [];
	var currentIdx = -1;

	function clearMarks() {
		marks.forEach(function(m) {
			var parent = m.parentNode;
			parent.replaceChild(document.createTextNode(m.textContent), m);
			parent.normalize();
		});
		marks = [];
		currentIdx = -1;
		document.getElementById("find-count").textContent = "";
	}

	function doSearch(query) {
		clearMarks();
		if (!query) return;
		var walker = document.createTreeWalker(document.getElementById("preview") || document.body, NodeFilter.SHOW_TEXT, null);
		var textNodes = [];
		while (walker.nextNode()) textNodes.push(walker.currentNode);
		var lower = query.toLowerCase();
		textNodes.forEach(function(node) {
			var text = node.textContent;
			var idx = text.toLowerCase().indexOf(lower);
			if (idx === -1) return;
			var parts = [];
			var last = 0;
			while (idx !== -1) {
				if (idx > last) parts.push(document.createTextNode(text.slice(last, idx)));
				var mark = document.createElement("mark");
				mark.style.cssText = "background:#f9e2af;color:#1e1e2e;border-radius:2px;padding:0 1px;";
				mark.textContent = text.slice(idx, idx + query.length);
				parts.push(mark);
				marks.push(mark);
				last = idx + query.length;
				idx = text.toLowerCase().indexOf(lower, last);
			}
			if (last < text.length) parts.push(document.createTextNode(text.slice(last)));
			var parent = node.parentNode;
			parts.forEach(function(p) { parent.insertBefore(p, node); });
			parent.removeChild(node);
		});
		document.getElementById("find-count").textContent = marks.length + " found";
		if (marks.length > 0) {
			currentIdx = 0;
			marks[0].scrollIntoView({ block: "center" });
			marks[0].style.background = "#fab387";
		}
	}

	var findBarVisible = false;

	window.showFindBar = function() {
		if (findBarVisible) {
			window.hideFindBar();
			return;
		}
		findBarVisible = true;
		bar.style.transform = "translateY(0)";
		bar.style.opacity = "1";
		bar.style.pointerEvents = "auto";
		var input = document.getElementById("find-input");
		input.value = "";
		clearMarks();
		input.focus();
	};

	window.hideFindBar = function() {
		findBarVisible = false;
		bar.style.transform = "translateY(100%)";
		bar.style.opacity = "0";
		bar.style.pointerEvents = "none";
		clearMarks();
	};

	document.getElementById("find-input").addEventListener("input", function(e) {
		doSearch(e.target.value);
	});

	document.getElementById("find-input").addEventListener("keydown", function(e) {
		if (e.key === "Escape") {
			window.hideFindBar();
		} else if (e.key === "Enter" && marks.length > 0) {
			if (currentIdx >= 0) marks[currentIdx].style.background = "#f9e2af";
			currentIdx = (currentIdx + 1) % marks.length;
			marks[currentIdx].style.background = "#fab387";
			marks[currentIdx].scrollIntoView({ block: "center" });
		}
	});
})();

window.webkit.messageHandlers.markdownPreviewHandler.postMessage({ type: "ready" });
