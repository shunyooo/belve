// Diff view 用 Shiki ハイライタ。ChangesView の `<td class="code">` セル群を
// language ごとにまとめて codeToHast で highlight し、各行を innerHTML 置換する。
//
// ChangesView (Swift 側) からは:
//   - `<div class="file-section" data-lang="python">...` のように lang を data 属性で渡す
//   - ページ末尾で `window.shikiHighlightDiff()` を呼ぶ
//
// 仕様:
//   - diff 行プレフィックス (+ / - / space) は色付け対象外で残す
//   - hunk header (`@@ ... @@`) はそのまま (= shiki 走らせない)
//   - 言語非対応 / 未マッチ拡張子はノーオペ (= プレーン表示にフォールバック)

import { createHighlighter } from "shiki";

// Eagerly load common langs/theme. これだけで bundle は ~3 MB 程度。
// それ以外の言語のファイル diff はプレーン表示のまま。
const SHIKI_LANGS = [
	"javascript", "typescript", "tsx", "jsx",
	"python", "swift", "go", "rust", "java",
	"json", "yaml", "markdown", "html", "css",
	"shellscript", "sql", "c", "cpp", "ruby", "php",
	"toml", "xml", "diff"
];

const SHIKI_THEME = "github-dark";

// github-dark の default foreground (#e1e4e8 / #d1d5da) はやや暗いので brighter に remap。
const COLOR_REPLACEMENTS = {
	"#e1e4e8": "#FFFFFF",
	"#d1d5da": "#FFFFFF",
	"#79b8ff": "#A5D6FF",
	"#b392f0": "#C19DEC"
};

let highlighterPromise = null;
function getHighlighter() {
	if (!highlighterPromise) {
		highlighterPromise = createHighlighter({
			themes: [SHIKI_THEME],
			langs: SHIKI_LANGS
		});
	}
	return highlighterPromise;
}

// Mac 側で生成した file-section の data-lang は CodeMirror 形式 (e.g. "javascript")。
// Shiki にも同じ名前で渡せばだいたい一致するが、cpp/c/shellscript 等で違うので map。
const LANG_REMAP = {
	"shell": "shellscript",
	"sh": "shellscript",
	"bash": "shellscript",
	"zsh": "shellscript"
};

function normalizeLang(lang) {
	if (!lang) return null;
	const normalized = LANG_REMAP[lang] || lang;
	return SHIKI_LANGS.includes(normalized) ? normalized : null;
}

// `td.code` の textContent は `+` / `-` / ` ` プレフィックス込み (= 行頭文字)。
// Shiki に渡すコードからは prefix を剥がし、結果に prefix を戻す。
function splitPrefix(text) {
	if (text.length === 0) return { prefix: "", body: "" };
	const first = text[0];
	if (first === "+" || first === "-" || first === " ") {
		return { prefix: first, body: text.slice(1) };
	}
	return { prefix: "", body: text };
}

function escapeHTML(s) {
	return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

window.shikiHighlightDiff = async function() {
	const sections = document.querySelectorAll(".file-section[data-lang]");
	if (sections.length === 0) return;

	// 必要な lang を集めて先に highlighter を準備 (= ensureLanguage 漏れ防止)
	const highlighter = await getHighlighter();

	for (const section of sections) {
		const rawLang = section.getAttribute("data-lang");
		const lang = normalizeLang(rawLang);
		if (!lang) continue;

		// add / del / context 行をひとつのバッファに連結し、行番号で結果を map し直す。
		// hunk 行は除外 (= shiki に通さない)。
		const codeCells = section.querySelectorAll("tr.add td.code, tr.del td.code, tr td.code:not(.hunk-code)");
		const targetRows = [];
		for (const td of codeCells) {
			const tr = td.parentElement;
			if (tr.classList.contains("hunk") || tr.classList.contains("expand-row")) continue;
			targetRows.push(td);
		}
		if (targetRows.length === 0) continue;

		// 各セル個別に highlight (= 1 行ずつなので速い)。バッファ連結すると
		// indentation 系の TextMate state がリセットされない利点があるが、行単位
		// でも diff 用途では十分。
		for (const td of targetRows) {
			const text = td.textContent || "";
			const { prefix, body } = splitPrefix(text);
			if (body.length === 0) continue;
			try {
				const tokens = highlighter.codeToTokensBase(body, {
					lang,
					theme: SHIKI_THEME,
					colorReplacements: COLOR_REPLACEMENTS
				});
				let html = "";
				for (const line of tokens) {
					for (const tok of line) {
						const safe = escapeHTML(tok.content);
						const color = tok.color || "#EDF3F9";
						html += `<span style="color:${color}">${safe}</span>`;
					}
				}
				// prefix は元のまま (= diff 行カラーは tr.add/del 側で着色済み)
				td.innerHTML = (prefix ? escapeHTML(prefix) : "") + html;
			} catch (err) {
				// 失敗時は元のテキストのまま (= サイレントフォールバック)
			}
		}
	}
};
