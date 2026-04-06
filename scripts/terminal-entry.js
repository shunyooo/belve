import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';

const fitAddon = new FitAddon();

const term = new Terminal({
	cursorBlink: true,
	cursorStyle: 'block',
	fontSize: 13,
	fontFamily: 'Menlo, Monaco, "Courier New", monospace',
	allowProposedApi: true,
	macOptionIsMeta: true,
	scrollback: 10000,
	theme: {
		background: '#1e1e2e',
		foreground: '#cdd6f4',
		cursor: '#f5e0dc',
		selectionBackground: '#585b70',
		black: '#45475a',
		red: '#f38ba8',
		green: '#a6e3a1',
		yellow: '#f9e2af',
		blue: '#89b4fa',
		magenta: '#f5c2e7',
		cyan: '#94e2d5',
		white: '#bac2de',
		brightBlack: '#585b70',
		brightRed: '#f38ba8',
		brightGreen: '#a6e3a1',
		brightYellow: '#f9e2af',
		brightBlue: '#89b4fa',
		brightMagenta: '#f5c2e7',
		brightCyan: '#94e2d5',
		brightWhite: '#a6adc8',
	}
});

term.loadAddon(fitAddon);
term.loadAddon(new WebLinksAddon());

term.open(document.getElementById('terminal'));
fitAddon.fit();

// Bridge: Swift -> JS
window.terminalWrite = function(base64) {
	const bytes = atob(base64);
	const arr = new Uint8Array(bytes.length);
	for (let i = 0; i < bytes.length; i++) arr[i] = bytes.charCodeAt(i);
	term.write(arr);
};

window.terminalFocus = function(focused) {
	if (focused) term.focus();
	else term.blur();
};

window.terminalSetTheme = function(themeJson) {
	term.options.theme = JSON.parse(themeJson);
};

window.terminalClear = function() {
	term.clear();
};

// Bridge: JS -> Swift
function postMessage(msg) {
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terminalHandler) {
		window.webkit.messageHandlers.terminalHandler.postMessage(msg);
	}
}

// Input from user -> Swift PTY
term.onData(function(data) {
	postMessage({ type: 'input', data: btoa(data) });
});

// Binary input (for special keys)
term.onBinary(function(data) {
	postMessage({ type: 'input', data: btoa(data) });
});

// Resize with debounce
let resizeTimeout = null;
const resizeObserver = new ResizeObserver(function() {
	if (resizeTimeout) clearTimeout(resizeTimeout);
	resizeTimeout = setTimeout(function() {
		fitAddon.fit();
		postMessage({ type: 'resize', cols: term.cols, rows: term.rows });
	}, 16);
});
resizeObserver.observe(document.getElementById('terminal'));

// Title change
term.onTitleChange(function(title) {
	postMessage({ type: 'title', title: title });
});

// Bell
term.onBell(function() {
	postMessage({ type: 'bell' });
});

// Selection -> clipboard
term.onSelectionChange(function() {
	const sel = term.getSelection();
	if (sel) {
		postMessage({ type: 'selection', text: sel });
	}
});

// Paste handling: listen for Cmd+V
document.addEventListener('keydown', function(e) {
	if (e.metaKey && e.key === 'v') {
		e.preventDefault();
		postMessage({ type: 'paste' });
	}
	// Cmd+C with selection -> copy
	if (e.metaKey && e.key === 'c' && term.hasSelection()) {
		e.preventDefault();
		postMessage({ type: 'copy', text: term.getSelection() });
	}
	// Cmd+key shortcuts — send to Swift via postMessage
	if (e.metaKey && !['c', 'v'].includes(e.key)) {
		e.preventDefault();
		postMessage({ type: 'shortcut', key: e.key, shift: e.shiftKey });
	}
});

// Notify Swift that terminal is ready (after layout settles)
// Double-fit: first to get initial size, then after a short delay for WKWebView layout
requestAnimationFrame(function() {
	fitAddon.fit();
	postMessage({ type: 'ready', cols: term.cols, rows: term.rows });
	// Second fit after WKWebView finishes layout
	setTimeout(function() {
		fitAddon.fit();
		postMessage({ type: 'resize', cols: term.cols, rows: term.rows });
	}, 100);
});
