import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, basicSetup } from "codemirror";
import { oneDark } from "@codemirror/theme-one-dark";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";

const languageCompartment = new Compartment();

const theme = EditorView.theme({
	"&": {
		height: "100%",
		fontSize: "13px",
	},
	".cm-scroller": {
		fontFamily: "'SF Mono', Menlo, Monaco, 'Courier New', monospace",
	},
});

let view: EditorView | null = null;
let debounceTimer: ReturnType<typeof setTimeout> | null = null;

function getLanguageExtension(lang: string) {
	switch (lang) {
		case "javascript":
		case "typescript":
		case "jsx":
		case "tsx":
			return javascript({ jsx: true, typescript: lang.includes("ts") });
		case "python":
			return python();
		case "html":
			return html();
		case "css":
			return css();
		case "json":
			return json();
		case "markdown":
			return markdown();
		default:
			return [];
	}
}

function detectLanguage(filename: string): string {
	const ext = filename.split(".").pop()?.toLowerCase() || "";
	const map: Record<string, string> = {
		js: "javascript",
		jsx: "jsx",
		ts: "typescript",
		tsx: "tsx",
		py: "python",
		html: "html",
		htm: "html",
		css: "css",
		json: "json",
		md: "markdown",
		swift: "javascript", // basic highlighting fallback
		sh: "javascript",
		bash: "javascript",
		zsh: "javascript",
		yml: "javascript",
		yaml: "javascript",
		toml: "javascript",
	};
	return map[ext] || "";
}

// Called from Swift to open a file
(window as any).editorOpenFile = (content: string, filename: string) => {
	const lang = detectLanguage(filename);
	const langExt = getLanguageExtension(lang);

	if (view) {
		view.destroy();
	}

	const state = EditorState.create({
		doc: content,
		extensions: [
			basicSetup,
			oneDark,
			theme,
			languageCompartment.of(langExt),
			EditorView.updateListener.of((update) => {
				if (update.docChanged) {
					if (debounceTimer) clearTimeout(debounceTimer);
					debounceTimer = setTimeout(() => {
						const content = update.state.doc.toString();
						(window as any).webkit?.messageHandlers?.editorHandler?.postMessage({
							type: "contentChanged",
							content: content,
						});
					}, 500);
				}
			}),
		],
	});

	view = new EditorView({
		state,
		parent: document.getElementById("editor")!,
	});
};

// Called from Swift to get content
(window as any).editorGetContent = () => {
	return view?.state.doc.toString() || "";
};

// Signal ready
(window as any).webkit?.messageHandlers?.editorHandler?.postMessage({
	type: "ready",
});
