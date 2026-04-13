import { basicSetup } from "codemirror";
import { Compartment, EditorState, StateEffect, StateField } from "@codemirror/state";
import { Decoration, EditorView } from "@codemirror/view";
import { oneDark } from "@codemirror/theme-one-dark";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { java } from "@codemirror/lang-java";
import { cpp } from "@codemirror/lang-cpp";
import { xml } from "@codemirror/lang-xml";
import { sql } from "@codemirror/lang-sql";
import { php } from "@codemirror/lang-php";
import { yaml } from "@codemirror/lang-yaml";
import { sass } from "@codemirror/lang-sass";

const languageCompartment = new Compartment();
const editorContainer = document.getElementById("editor");

let editorView = null;
let contentChangeTimeout = null;
let currentFilename = "";
let currentLanguage = "";
let isMetaPressed = false;
let currentHoverTarget = null;
let hoverRequestId = 0;

const setJumpHoverEffect = StateEffect.define();
const clearJumpHoverEffect = StateEffect.define();
const setDiffMarkersEffect = StateEffect.define();

const jumpHoverField = StateField.define({
	create() {
		return Decoration.none;
	},
	update(decorations, tr) {
		decorations = decorations.map(tr.changes);
		for (const effect of tr.effects) {
			if (effect.is(clearJumpHoverEffect)) {
				return Decoration.none;
			}
			if (effect.is(setJumpHoverEffect)) {
				const { from, to } = effect.value;
				return Decoration.set([
					Decoration.mark({ class: "cm-jumpTarget" }).range(from, to)
				]);
			}
		}
		return decorations;
	},
	provide(field) {
		return EditorView.decorations.from(field);
	}
});

const diffMarkerField = StateField.define({
	create() { return Decoration.none; },
	update(decorations, tr) {
		for (const effect of tr.effects) {
			if (effect.is(setDiffMarkersEffect)) {
				const marks = [];
				for (const { from, to, type } of effect.value) {
					const cls = type === "add" ? "cm-diff-add" : type === "modify" ? "cm-diff-modify" : "cm-diff-delete";
					for (let line = from; line <= to; line++) {
						if (line > 0 && line <= tr.state.doc.lines) {
							const lineObj = tr.state.doc.line(line);
							marks.push(Decoration.line({ class: cls }).range(lineObj.from));
						}
					}
				}
				return Decoration.set(marks, true);
			}
		}
		return decorations.map(tr.changes);
	},
	provide(field) { return EditorView.decorations.from(field); }
});

const customTheme = EditorView.theme({
	"&": {
		height: "100%",
		fontSize: "13px",
		backgroundColor: "#1a1b26"
	},
	".cm-scroller": {
		fontFamily: "'SF Mono', Menlo, Monaco, 'Courier New', monospace"
	},
	".cm-content": {
		caretColor: "#c0caf5"
	},
	".cm-activeLine": {
		backgroundColor: "#232433"
	},
	".cm-activeLineGutter": {
		backgroundColor: "#232433"
	},
	".cm-selectionBackground, ::selection": {
		backgroundColor: "#33467c !important"
	},
	".cm-jumpTarget": {
		textDecoration: "underline",
		textDecorationColor: "#7aa2f7",
		textUnderlineOffset: "2px",
		cursor: "pointer"
	},
	".cm-diff-add": {
		borderLeft: "3px solid #9ece6a",
		paddingLeft: "1px"
	},
	".cm-diff-modify": {
		borderLeft: "3px solid #7aa2f7",
		paddingLeft: "1px"
	},
	".cm-diff-delete": {
		borderLeft: "3px solid #f7768e",
		paddingLeft: "1px"
	}
});

function postMessage(message) {
	if (window.webkit?.messageHandlers?.editorHandler) {
		window.webkit.messageHandlers.editorHandler.postMessage(message);
	}
}

function detectLanguage(filename) {
	const name = filename.split("/").pop()?.toLowerCase() ?? "";
	const ext = name.includes(".") ? name.split(".").pop() : "";

	if (name === "dockerfile") return "shell";
	if (name === "makefile") return "shell";

	return {
		js: "javascript",
		mjs: "javascript",
		cjs: "javascript",
		jsx: "jsx",
		ts: "typescript",
		tsx: "tsx",
		py: "python",
		pyi: "python",
		html: "html",
		htm: "html",
		css: "css",
		json: "json",
		md: "markdown",
		rs: "rust",
		go: "go",
		java: "java",
		c: "c",
		h: "cpp",
		cpp: "cpp",
		cc: "cpp",
		cxx: "cpp",
		hpp: "cpp",
		xml: "xml",
		svg: "xml",
		plist: "xml",
		sql: "sql",
		php: "php",
		yaml: "yaml",
		yml: "yaml",
		sass: "sass",
		scss: "scss",
		sh: "shell",
		bash: "shell",
		zsh: "shell",
		toml: "yaml",
		rb: "ruby",
		kt: "java",
		swift: "swift"
	}[ext] || "";
}

function languageExtensionFor(language) {
	switch (language) {
	case "javascript":
		return javascript({ jsx: false, typescript: false });
	case "jsx":
		return javascript({ jsx: true, typescript: false });
	case "typescript":
		return javascript({ jsx: false, typescript: true });
	case "tsx":
		return javascript({ jsx: true, typescript: true });
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
	case "rust":
		return rust();
	case "go":
		return go();
	case "java":
		return java();
	case "c":
	case "cpp":
		return cpp();
	case "xml":
		return xml();
	case "sql":
		return sql();
	case "php":
		return php();
	case "yaml":
		return yaml();
	case "sass":
		return sass();
	default:
		return [];
	}
}

function identifierRangeAtPos(state, pos) {
	const line = state.doc.lineAt(pos);
	const lineText = line.text;
	let index = pos - line.from;

	if (index < 0 || index > lineText.length) return null;
	if (index === lineText.length && index > 0) index -= 1;

	const isIdentifierChar = (char) => /[A-Za-z0-9_$]/.test(char);
	const isIdentifierStart = (char) => /[A-Za-z_$]/.test(char);

	let start = index;
	let end = index;

	if (!isIdentifierChar(lineText[index] ?? "")) {
		if (index > 0 && isIdentifierChar(lineText[index - 1])) {
			start = index - 1;
			end = index - 1;
		} else {
			return null;
		}
	}

	while (start > 0 && isIdentifierChar(lineText[start - 1])) start -= 1;
	while (end < lineText.length && isIdentifierChar(lineText[end])) end += 1;

	const text = lineText.slice(start, end);
	if (!text || !isIdentifierStart(text[0])) return null;

	return {
		from: line.from + start,
		to: line.from + end,
		text
	};
}

function locationForPos(state, pos) {
	const line = state.doc.lineAt(pos);
	return {
		line: line.number,
		column: (pos - line.from) + 1
	};
}

function clearJumpHover(view = editorView) {
	currentHoverTarget = null;
	if (!view) return;
	view.dispatch({ effects: clearJumpHoverEffect.of(null) });
}

function requestJumpHover(view, identifier, position) {
	const location = locationForPos(view.state, position);
	const requestId = ++hoverRequestId;
	currentHoverTarget = {
		requestId,
		from: identifier.from,
		to: identifier.to,
		text: identifier.text
	};

	postMessage({
		type: "definitionHoverRequest",
		requestId,
		symbol: identifier.text,
		filename: currentFilename,
		language: currentLanguage,
		line: location.line,
		column: location.column
	});
}

function updateJumpHoverAtCoords(view, x, y, metaOverride = null) {
	const metaActive = metaOverride ?? isMetaPressed;
	if (!metaActive) {
		clearJumpHover(view);
		return false;
	}

	const position = view.posAtCoords({ x, y });
	if (position == null) {
		clearJumpHover(view);
		return false;
	}

	const identifier = identifierRangeAtPos(view.state, position);
	if (!identifier) {
		clearJumpHover(view);
		return false;
	}

	if (
		currentHoverTarget &&
		currentHoverTarget.from === identifier.from &&
		currentHoverTarget.to === identifier.to &&
		currentHoverTarget.text === identifier.text
	) {
		return false;
	}

	view.dispatch({
		effects: setJumpHoverEffect.of({
			from: identifier.from,
			to: identifier.to
		})
	});
	requestJumpHover(view, identifier, position);
	return false;
}

function revealLocation(lineNumber, columnNumber) {
	if (!editorView || !lineNumber || lineNumber < 1) return;

	const safeLine = Math.min(Math.max(1, lineNumber), editorView.state.doc.lines);
	const line = editorView.state.doc.line(safeLine);
	const safeColumn = Math.max(1, columnNumber ?? 1);
	const position = Math.min(line.from + safeColumn - 1, line.to);

	editorView.dispatch({
		selection: { anchor: position },
		effects: EditorView.scrollIntoView(position, { y: "center", x: "center" })
	});
	editorView.focus();
}

function createEditorState(content, filename) {
	currentFilename = filename;
	currentLanguage = detectLanguage(filename);

	return EditorState.create({
		doc: content,
		extensions: [
			basicSetup,
			oneDark,
			customTheme,
			jumpHoverField,
			diffMarkerField,
			languageCompartment.of(languageExtensionFor(currentLanguage)),
			EditorView.updateListener.of((update) => {
				if (!update.docChanged) return;
				clearTimeout(contentChangeTimeout);
				contentChangeTimeout = setTimeout(() => {
					postMessage({
						type: "contentChanged",
						content: update.state.doc.toString()
					});
				}, 250);
			}),
			EditorView.domEventHandlers({
				mousemove(event, view) {
					return updateJumpHoverAtCoords(view, event.clientX, event.clientY, event.metaKey || isMetaPressed);
				},
				mouseleave(_event, view) {
					clearJumpHover(view);
					return false;
				},
				mousedown(event, view) {
					if (!event.metaKey) return false;
					const position = view.posAtCoords({ x: event.clientX, y: event.clientY });
					if (position == null) return false;
					const identifier = identifierRangeAtPos(view.state, position);
					if (!identifier) return false;

					const location = locationForPos(view.state, position);
					event.preventDefault();
					postMessage({
						type: "definitionRequest",
						symbol: identifier.text,
						filename: currentFilename,
						language: currentLanguage,
						line: location.line,
						column: location.column
					});
					return true;
				}
			})
		]
	});
}

window.editorOpenFile = function(content, filename, lineNumber = null, columnNumber = null) {
	clearTimeout(contentChangeTimeout);

	if (editorView) {
		editorView.destroy();
		editorView = null;
	}

	editorView = new EditorView({
		state: createEditorState(content, filename),
		parent: editorContainer
	});

	if (lineNumber != null) {
		requestAnimationFrame(() => {
			revealLocation(lineNumber, columnNumber);
		});
	}
};

// Set diff markers: [{from: lineNum, to: lineNum, type: "add"|"modify"|"delete"}, ...]
window.editorSetDiffMarkers = function(markers) {
	if (!editorView) return;
	editorView.dispatch({ effects: setDiffMarkersEffect.of(markers) });
	renderScrollbarMarkers(markers);
};

// Render diff markers as a fixed overlay mapped to the full file height
function renderScrollbarMarkers(markers) {
	var old = document.getElementById("diff-scrollbar-markers");
	if (old) old.remove();
	if (!markers.length || !editorView) return;

	var totalLines = editorView.state.doc.lines;
	if (totalLines <= 0) return;

	var container = document.createElement("div");
	container.id = "diff-scrollbar-markers";
	container.style.cssText = "position:fixed;top:0;right:0;bottom:0;width:6px;pointer-events:none;z-index:100;";

	for (var i = 0; i < markers.length; i++) {
		var m = markers[i];
		var top = ((m.from - 1) / totalLines) * 100;
		var height = Math.max(0.3, ((m.to - m.from + 1) / totalLines) * 100);
		var color = m.type === "add" ? "#9ece6a" : m.type === "modify" ? "#7aa2f7" : "#f7768e";
		var bar = document.createElement("div");
		bar.style.cssText = "position:absolute;right:0;width:6px;border-radius:1px;top:" + top + "%;height:" + height + "%;min-height:2px;background:" + color + ";opacity:0.8;";
		container.appendChild(bar);
	}

	document.body.appendChild(container);
}

window.editorRevealLocation = function(lineNumber, columnNumber = null) {
	revealLocation(lineNumber, columnNumber);
};

window.editorGetContent = function() {
	return editorView?.state.doc.toString() || "";
};

window.editorSetMetaPressed = function(isPressed) {
	isMetaPressed = Boolean(isPressed);
	if (!isMetaPressed) {
		clearJumpHover();
	}
};

window.editorSetJumpHoverResult = function(requestId, canJump) {
	if (!editorView || !currentHoverTarget) return;
	if (currentHoverTarget.requestId !== requestId) return;
	if (!canJump) {
		editorView.dispatch({ effects: clearJumpHoverEffect.of(null) });
		return;
	}
	editorView.dispatch({
		effects: setJumpHoverEffect.of({
			from: currentHoverTarget.from,
			to: currentHoverTarget.to
		})
	});
};

window.addEventListener("blur", () => {
	isMetaPressed = false;
	clearJumpHover();
});

document.addEventListener("keyup", (event) => {
	if (event.key === "Meta") {
		isMetaPressed = false;
		clearJumpHover();
	}
});

document.addEventListener("keydown", (event) => {
	if (event.key === "Meta") {
		isMetaPressed = true;
	}
});

postMessage({ type: "ready" });
