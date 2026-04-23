// Belve Markdown preview (read-only). marked.js で md → HTML レンダリング。
// 編集機能は持たない (= 編集したい時は Cmd+E 等で CodeMirror に切り替える)。
import { marked } from "marked";

marked.setOptions({
	gfm: true,        // GitHub Flavored Markdown
	breaks: true,     // 単一改行を <br> に
});

const root = document.getElementById("preview");

window.markdownRender = function (md) {
	root.innerHTML = marked.parse(md || "");
};

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
