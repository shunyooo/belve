import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
// WebLinksAddon replaced by custom link provider (supports multi-line URLs)

const fitAddon = new FitAddon();
const terminalContainer = document.getElementById('terminal');

const term = new Terminal({
	cursorBlink: true,
	cursorStyle: 'block',
	fontSize: 13,
	fontFamily: 'Menlo, Monaco, "Courier New", monospace',
	allowProposedApi: true,
	macOptionIsMeta: true,
	scrollback: 1000,
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
// Build full URL by joining continuation lines. Returns {url, continuations: [{y, startX, endX}]}
function buildFullUrl(buf, startY, urlStart) {
	var url = urlStart;
	var line = buf.getLine(startY);
	var text = line.translateToString(true);
	var urlEndPos = text.indexOf(urlStart) + urlStart.length;
	var continuations = [];
	if (urlEndPos < text.length - 2) return { url: url, continuations: continuations };

	var nextY = startY + 1;
	while (nextY < buf.length) {
		var nextLine = buf.getLine(nextY);
		if (!nextLine) break;
		var nextText = nextLine.translateToString(true);
		var trimmed = nextText.replace(/^\s+/, '');
		var indent = nextText.length - trimmed.length;
		var cont = trimmed.match(/^([a-zA-Z0-9_\-\.\/~%@:?&=#]+)/);
		if (cont && !trimmed.match(/^https?:\/\//)) {
			url += cont[1];
			continuations.push({ y: nextY + 1, startX: indent + 1, endX: indent + cont[1].length });
			if (cont[1].match(/\.(html?|php|json|xml|txt|pdf|png|jpg|gif|svg|css|js|md|py|go|rs|ts|jsx|tsx)$/i)) break;
			nextY++;
		} else { break; }
	}
	return { url: url, continuations: continuations };
}

// Persistent overlay container for link underlines (outside xterm-screen to avoid reflow)
var _underlineContainer = document.createElement('div');
_underlineContainer.style.cssText = 'position:absolute;top:0;left:0;right:0;bottom:0;pointer-events:none;z-index:5;';
document.getElementById('terminal').appendChild(_underlineContainer);

function showPeerUnderlines(ranges) {
	_underlineContainer.innerHTML = '';
	var dims = term._core._renderService.dimensions;
	var cellW = dims.css.cell.width;
	var cellH = dims.css.cell.height;
	ranges.forEach(function(r) {
		var viewY = r.y - 1 - term.buffer.active.viewportY;
		if (viewY < 0 || viewY >= term.rows) return;
		var div = document.createElement('div');
		div.style.cssText = 'position:absolute;pointer-events:none;' +
			'left:' + ((r.startX - 1) * cellW) + 'px;' +
			'top:' + (viewY * cellH + cellH - 1) + 'px;' +
			'width:' + ((r.endX - r.startX + 1) * cellW) + 'px;' +
			'height:1px;background:#7aa2f7;';
		_underlineContainer.appendChild(div);
	});
}
function hidePeerUnderlines() {
	_underlineContainer.innerHTML = '';
}

// Custom URL link provider (with cache to prevent hover flicker)
var _linkCache = {};
var _linkCacheVersion = 0;
var _wasAltBuffer = false;

term.onWriteParsed(function() {
	_linkCache = {}; _linkCacheVersion++;
	var isAlt = term.buffer.active === term.buffer.alternate;
	if (_wasAltBuffer && !isAlt) {
		term.scrollToBottom();
	}
	_wasAltBuffer = isAlt;
});


term.registerLinkProvider({
	provideLinks: function(y, callback) {
		var cacheKey = y + ':' + _linkCacheVersion;
		if (_linkCache[cacheKey]) { callback(_linkCache[cacheKey]); return; }
		var buf = term.buffer.active;
		var line = buf.getLine(y - 1);
		if (!line) { callback([]); return; }
		var text = line.translateToString(true);
		var links = [];

		// URLs starting on this line
		var urlRegex = /https?:\/\/[^\s<>"'`)\]]+/g;
		var m;
		while ((m = urlRegex.exec(text)) !== null) {
			var result = buildFullUrl(buf, y - 1, m[0]);
			var sx = mapStringIndexToCell(line, m.index) + 1;
			var ex = mapStringIndexToCell(line, m.index + m[0].length);
			var selfRange = { y: y, startX: sx, endX: ex };
			(function(u, self, peers) {
				var allRanges = [self].concat(peers);
				links.push({
					range: { start: { x: sx, y: y }, end: { x: ex, y: y } },
					text: u, decorations: { pointerCursor: true },
					activate: function() { postMessage({ type: 'openUrl', url: u }); },
					hover: function() { showPeerUnderlines(allRanges); },
					leave: function() { hidePeerUnderlines(); }
				});
			})(result.url, selfRange, result.continuations);
		}

		// Continuation of URL from previous line
		if (links.length === 0 && y > 1) {
			var prevLine = buf.getLine(y - 2);
			if (prevLine) {
				var prevText = prevLine.translateToString(true);
				var prevMatch = prevText.match(/(https?:\/\/[^\s<>"'`)\]]+)$/);
				if (prevMatch && prevMatch.index + prevMatch[1].length >= prevText.length - 2) {
					var trimmed = text.replace(/^\s+/, '');
					var indent = text.length - trimmed.length;
					var cont = trimmed.match(/^([a-zA-Z0-9_\-\.\/~%@:?&=#]+)/);
					if (cont && !trimmed.match(/^https?:\/\//)) {
						var result = buildFullUrl(buf, y - 2, prevMatch[1]);
						var peerSx = mapStringIndexToCell(prevLine, prevMatch.index) + 1;
						var peerEx = mapStringIndexToCell(prevLine, prevMatch.index + prevMatch[1].length);
						var peerRange = { y: y - 1, startX: peerSx, endX: peerEx };
						var selfRange = { y: y, startX: indent + 1, endX: indent + cont[1].length };
						(function(u, allR) {
							links.push({
								range: { start: { x: indent + 1, y: y }, end: { x: indent + cont[1].length, y: y } },
								text: u, decorations: { pointerCursor: true },
								activate: function() { postMessage({ type: 'openUrl', url: u }); },
								hover: function() { showPeerUnderlines(allR); },
								leave: function() { hidePeerUnderlines(); }
							});
						})(result.url, [peerRange, selfRange]);
					}
				}
			}
		}

		_linkCache[cacheKey] = links;
		callback(links);
	}
});


term.attachCustomKeyEventHandler(function(e) {
	if (e.key === 'Enter' && e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
		if (e.type === 'keydown') {
			postMessage({ type: 'input', data: utf8ToBase64('\u001b[13;2u') });
		}
		e.preventDefault();
		e.stopPropagation();
		return false;
	}
	return true;
});

term.open(terminalContainer);
window.term = term;
window.fitAddon = fitAddon;

// Debug: resize terminal and PTY to specific cols/rows
window.debugResize = function(cols, rows) {
	var before = { cols: term.cols, rows: term.rows };
	term.resize(cols, rows);
	var after = { cols: term.cols, rows: term.rows };
	postMessage({ type: 'resize', cols: cols, rows: rows });
	postMessage({ type: 'log', msg: 'debugResize before=' + JSON.stringify(before) + ' after=' + JSON.stringify(after) });
	return after;
};

// Debug: report current dimensions
window.debugDimensions = function() {
	var d = term._core._renderService.dimensions;
	var t = document.getElementById('terminal');
	var rect = t.getBoundingClientRect();
	return {
		termCols: term.cols, termRows: term.rows,
		cellW: d.css.cell.width, cellH: d.css.cell.height,
		innerW: window.innerWidth, innerH: window.innerHeight,
		rectW: rect.width, rectH: rect.height,
		cssW: t.style.width, cssH: t.style.height
	};
};
// Don't call fitAddon.fit() here — WKWebView frame isn't set yet.
// The correct size will be applied by Swift via updateNSView → terminalFit().

const terminalPathRegex = /(?:^|[\s("'`\[])(\.{1,2}\/[^\s"'`)\]]+|\/[^\s"'`)\]]+|(?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+)(?::\d+)?(?::\d+)?/g;
let isMetaPressed = false;
let hoveredPathLink = null;
let pathLinkProviderDisposable = null;

function updateHoveredPathDecorations() {
	if (!hoveredPathLink || !hoveredPathLink.decorations) return;
	hoveredPathLink.decorations.underline = isMetaPressed;
	hoveredPathLink.decorations.pointerCursor = isMetaPressed;
}

window.terminalSetMetaPressed = function(pressed) {
	setMetaPressed(!!pressed);
};

function setMetaPressed(pressed) {
	isMetaPressed = pressed;
	if (isMetaPressed) {
		ensurePathLinkProvider();
	} else {
		if (hoveredPathLink && hoveredPathLink.decorations) {
			hoveredPathLink.decorations.underline = false;
			hoveredPathLink.decorations.pointerCursor = false;
		}
		hoveredPathLink = null;
		if (pathLinkProviderDisposable) {
			pathLinkProviderDisposable.dispose();
			pathLinkProviderDisposable = null;
		}
	}
	updateHoveredPathDecorations();
}

function mapStringIndexToCell(line, targetIndex) {
	const cell = line.getCell(0);
	if (!cell) return 0;

	let stringOffset = 0;
	for (let x = 0; x < line.length; x++) {
		line.getCell(x, cell);
		const chars = cell.getChars();
		const width = cell.getWidth();
		if (!width) continue;

		const charLength = chars.length || 1;
		if (stringOffset >= targetIndex) {
			return x;
		}
		stringOffset += charLength;
		if (stringOffset > targetIndex) {
			return x;
		}
	}

	return line.length;
}

function ensurePathLinkProvider() {
	if (pathLinkProviderDisposable) return;
	pathLinkProviderDisposable = term.registerLinkProvider({
		provideLinks(y, callback) {
			const line = term.buffer.active.getLine(y - 1);
			if (!line) {
				callback([]);
				return;
			}

			const text = line.translateToString(true);
			const links = [];
			terminalPathRegex.lastIndex = 0;
			let match;

			while ((match = terminalPathRegex.exec(text)) !== null) {
				const rawPath = match[1];
				if (!rawPath) continue;
				const startIndex = match.index + match[0].lastIndexOf(rawPath);
				const endIndex = startIndex + rawPath.length;
				const startCell = mapStringIndexToCell(line, startIndex);
				const endCell = mapStringIndexToCell(line, endIndex);

				const link = {
					range: {
						start: { x: startCell + 1, y },
						end: { x: Math.max(startCell + 1, endCell), y }
					},
					text: rawPath,
					decorations: {
						underline: true,
						pointerCursor: true
					},
					hover: () => {
						hoveredPathLink = link;
					},
					leave: () => {
						hoveredPathLink = null;
					},
					activate: () => {
						postMessage({ type: 'openPath', path: rawPath });
					}
				};
				links.push(link);
			}

			callback(links);
		}
	});
}


// Fit terminal to container, returning actual cols/rows.
// Called from Swift after layout settles — uses fitAddon which accounts for
// scrollbar width, padding, and actual DOM dimensions.
window.terminalFit = function() {
	if (!window.term || !window.fitAddon) return null;
	var dims = fitAddon.proposeDimensions();
	if (!dims || dims.cols < 2 || dims.rows < 1) return null;
	term.resize(dims.cols, dims.rows);
	term.scrollToBottom();
	return { cols: dims.cols, rows: dims.rows };
};

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

window.terminalGetSelection = function() {
	return term.getSelection();
};

window.terminalHasSelection = function() {
	return term.hasSelection();
};

// Bridge: JS -> Swift
function postMessage(msg) {
	if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terminalHandler) {
		window.webkit.messageHandlers.terminalHandler.postMessage(msg);
	}
}

function utf8ToBase64(text) {
	const bytes = new TextEncoder().encode(text);
	let binary = '';
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary);
}

// Input from user -> Swift PTY
term.onData(function(data) {
	postMessage({ type: 'input', data: utf8ToBase64(data) });
});

// Binary input (for special keys)
term.onBinary(function(data) {
	postMessage({ type: 'input', data: btoa(data) });
});

// ResizeObserver — notify Swift after viewport settles (300ms debounce)
let resizeTimeout = null;
const resizeObserver = new ResizeObserver(function() {
	if (resizeTimeout) clearTimeout(resizeTimeout);
	resizeTimeout = setTimeout(function() {
		postMessage({ type: 'viewportChanged' });
	}, 300);
});
resizeObserver.observe(terminalContainer);

// Title change
term.onTitleChange(function(title) {
	postMessage({ type: 'title', title: title });
});

// Bell
term.onBell(function() {
	postMessage({ type: 'bell' });
});

// Selection UX: show text cursor only while dragging, default cursor otherwise.
var _isDragging = false;
var _terminalEl = document.querySelector('.xterm');

document.addEventListener('mousedown', function() {
	_isDragging = true;
	if (_terminalEl) _terminalEl.style.cursor = 'text';
	// Clear previous selection on new click (unless starting a new drag)
	if (term.hasSelection()) {
		requestAnimationFrame(function() {
			if (!term.hasSelection() || term.getSelection() === '') {
				term.clearSelection();
			}
		});
	}
}, true);

document.addEventListener('mouseup', function() {
	_isDragging = false;
	if (_terminalEl) _terminalEl.style.cursor = '';
}, true);

// Detect stuck drag state: if mouse moves without any button pressed, end drag.
// WKWebView can miss mouseup events, leaving xterm in selection-extend mode.
document.addEventListener('mousemove', function(e) {
	if (_isDragging && e.buttons === 0) {
		_isDragging = false;
		if (_terminalEl) _terminalEl.style.cursor = '';
		// Synthesize mouseup to release xterm's internal selection state
		var up = new MouseEvent('mouseup', { bubbles: true, clientX: e.clientX, clientY: e.clientY });
		e.target.dispatchEvent(up);
	}
}, true);

// Selection -> clipboard
term.onSelectionChange(function() {
	var sel = term.getSelection();
	if (sel) {
		postMessage({ type: 'selection', text: sel });
	}
});

// Paste handling: listen for Cmd+V
document.addEventListener('keydown', function(e) {
	if (e.key === 'Enter' && e.shiftKey) {
		postMessage({ type: 'log', msg: 'document keydown: Shift+Enter detected' });
	}
	if (e.key === 'Meta') {
		setMetaPressed(true);
	}
	if (e.metaKey) {
		postMessage({
			type: 'log',
			msg: 'keydown key=' + e.key + ' code=' + e.code + ' meta=' + e.metaKey + ' shift=' + e.shiftKey
		});
	}
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

document.addEventListener('keyup', function(e) {
	if (e.key === 'Meta') {
		setMetaPressed(false);
	}
});

document.addEventListener('mousemove', function(e) {
	if (!hoveredPathLink) return;
	if (isMetaPressed !== e.metaKey) {
		setMetaPressed(e.metaKey);
	}
});

window.addEventListener('blur', function() {
	setMetaPressed(false);
});

// Notify Swift that terminal is ready
// Swift manages terminal size via updateNSView, so no fitAddon.fit() here.
requestAnimationFrame(function() {
	postMessage({ type: 'ready', cols: term.cols, rows: term.rows });
});
