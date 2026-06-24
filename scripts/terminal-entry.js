import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebglAddon } from '@xterm/addon-webgl';
import { SerializeAddon } from '@xterm/addon-serialize';
import { UnicodeGraphemesAddon } from '@xterm/addon-unicode-graphemes';
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
const serializeAddon = new SerializeAddon();
term.loadAddon(serializeAddon);
var unicodeGraphemes = new UnicodeGraphemesAddon();
term.loadAddon(unicodeGraphemes);
term.unicode.activeVersion = '15-graphemes';
// Set ambiguous-width characters to 2 cells (CJK locale).
// Access the provider through xterm's internal unicode service.
// Patch charProperties + wcwidth for specific ambiguous chars that render
// wide in CJK fonts (①-⓿ etc.) but NOT box drawing (─│┌).
function _isForceWide(cp) {
	return (cp >= 0x2460 && cp <= 0x24FF)   // Enclosed Alphanumerics ①-⓿
		|| (cp >= 0x3200 && cp <= 0x32FF)   // Enclosed CJK Letters ㈀-㋿
		|| (cp >= 0x1F200 && cp <= 0x1F2FF); // Enclosed Ideographic Supplement
}
try {
	for (var key in unicodeGraphemes) {
		var prov = unicodeGraphemes[key];
		if (prov && typeof prov === 'object' && typeof prov.charProperties === 'function') {
			(function(provider) {
				var origCharProps = provider.charProperties.bind(provider);
				var origWcwidth = provider.wcwidth.bind(provider);
				provider.charProperties = function(cp, preceding) {
					var result = origCharProps(cp, preceding);
					if (_isForceWide(cp)) {
						// Replace width bits (bits 1-2) with 2
						result = (result & ~0x6) | (2 << 1);
					}
					return result;
				};
				provider.wcwidth = function(cp) {
					if (_isForceWide(cp)) return 2;
					return origWcwidth(cp);
				};
			})(prov);
		}
	}
} catch(e) {}
// Build full URL by joining continuation lines. Returns {url, continuations: [{y, startX, endX}]}
function buildFullUrl(buf, startY, urlStart) {
	var url = urlStart;
	var continuations = [];
	// Two paths to recognize a wrapped URL:
	//   (a) xterm.js marked the next line as a soft-wrap continuation
	//       (= kernel-style auto-wrap from a single long write)
	//   (b) the URL filled the line right up to the last cell AND the next
	//       line starts with URL-safe chars. This catches TUIs (Ink/React,
	//       Claude Code login screen等) that pre-format output to terminal
	//       width and emit explicit \n at each column edge — visually wrapped
	//       but isWrapped=false.
	var firstLine = buf.getLine(startY);
	if (!firstLine) return { url: url, continuations: continuations };
	var firstText = firstLine.translateToString(true);
	// URL が行末で終わってればほぼ確実に wrap (= term.cols ピッタリじゃなくても許容)。
	// 厳密な width check は claude code みたいに余白残して wrap する出力を取りこぼす。
	var prevEndsAtEdge = firstText.endsWith(urlStart);

	var nextY = startY + 1;
	while (nextY < buf.length) {
		var nextLine = buf.getLine(nextY);
		if (!nextLine) break;
		var isWrapped = nextLine.isWrapped;
		if (!isWrapped && !prevEndsAtEdge) break;
		var nextText = nextLine.translateToString(true);
		// Indented continuation も許容: 先頭空白を skip して URL-safe chars を取る。
		var cont = nextText.match(/^(\s*)([a-zA-Z0-9_\-\.\/~%@:?&=#\+]+)/);
		// 次行が別 URL、リストマーカー (- text)、空行なら止める
		if (!cont || nextText.match(/^\s*https?:\/\//) || nextText.match(/^\s*-\s/)) break;
		var leading = cont[1].length;
		var contStr = cont[2];
		url += contStr;
		continuations.push({ y: nextY + 1, startX: leading + 1, endX: leading + contStr.length });
		if (leading + contStr.length < nextText.length) break;
		// 継続行も「URL-safe 文字で行末まで埋まってれば wrap」と判定。
		// gcloud 等のインデント付き折り返し URL に対応。
		prevEndsAtEdge = (leading + contStr.length >= nextText.trimEnd().length);
		nextY++;
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
// Cmd キー押下時のみリンク反応 (誤タップ防止)
var _metaPressed = false;
var _hoveredRanges = null;
function updateMetaState(pressed) {
	var changed = _metaPressed !== pressed;
	_metaPressed = pressed;
	if (!changed) return;
	if (pressed && _hoveredRanges) {
		showPeerUnderlines(_hoveredRanges);
	} else if (!pressed) {
		hidePeerUnderlines();
	}
}
document.addEventListener('keydown', function(e) { if (e.metaKey) updateMetaState(true); });
document.addEventListener('keyup', function(e) { if (!e.metaKey) updateMetaState(false); });
window.addEventListener('blur', function() { updateMetaState(false); });
window.terminalSetMetaPressed = function(v) { updateMetaState(v); };

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
		// URL末尾の句読点・記号を除去 (リスト内 URL で - や , が付着する)
		function trimUrlTrailing(url) {
			return url.replace(/[\-,;:!.\)]+$/, '');
		}
		var m;
		while ((m = urlRegex.exec(text)) !== null) {
			var result = buildFullUrl(buf, y - 1, m[0]);
			result.url = trimUrlTrailing(result.url);
			var sx = mapStringIndexToCell(line, m.index) + 1;
			var ex = mapStringIndexToCell(line, m.index + m[0].length);
			var selfRange = { y: y, startX: sx, endX: ex };
			(function(u, self, peers) {
				var allRanges = [self].concat(peers);
				links.push({
					range: { start: { x: sx, y: y }, end: { x: ex, y: y } },
					text: u, decorations: { pointerCursor: true },
					activate: function() { if (_metaPressed) postMessage({ type: 'openUrl', url: u }); },
					hover: function() { _hoveredRanges = allRanges; if (_metaPressed) showPeerUnderlines(allRanges); },
					leave: function() { _hoveredRanges = null; hidePeerUnderlines(); }
				});
			})(result.url, selfRange, result.continuations);
		}

		// Continuation of URL from a previous line. Walk upward to find the
		// origin line that starts the URL (may be 2+ lines above for long URLs
		// like gcloud OAuth). Each intermediate line must end with URL-safe chars.
		if (links.length === 0 && y > 1) {
			var cont = text.match(/^(\s*)([a-zA-Z0-9_\-\.\/~%@:?&=#\+]+)/);
			var isGitMarker = /^\s*[+\-*]\s/.test(text);
			if (cont && !isGitMarker && !text.match(/^\s*https?:\/\//)) {
				// Walk up to find the URL origin line
				var originY = null;
				var scanY = y - 2;
				while (scanY >= 0) {
					var scanLine = buf.getLine(scanY);
					if (!scanLine) break;
					var scanText = scanLine.translateToString(true);
					var urlMatch = scanText.match(/(https?:\/\/[^\s<>"'`)\]]+)$/);
					if (urlMatch) {
						originY = scanY;
						break;
					}
					// Check if this line is also a continuation (URL-safe chars filling the line)
					var scanCont = scanText.match(/^(\s*)([a-zA-Z0-9_\-\.\/~%@:?&=#\+]+)/);
					if (!scanCont || scanCont[1].length + scanCont[2].length < scanText.trimEnd().length) break;
					scanY--;
				}
				if (originY !== null) {
					var originLine = buf.getLine(originY);
					var originText = originLine.translateToString(true);
					var originMatch = originText.match(/(https?:\/\/[^\s<>"'`)\]]+)$/);
					if (originMatch) {
						var result = buildFullUrl(buf, originY, originMatch[1]);
						// Build allRanges: origin line + all continuations (from buildFullUrl) + this line
						var originSx = mapStringIndexToCell(originLine, originMatch.index) + 1;
						var originEx = mapStringIndexToCell(originLine, originMatch.index + originMatch[1].length);
						var allRanges = [{ y: originY + 1, startX: originSx, endX: originEx }].concat(result.continuations);
						var leadingSpaces = cont[1].length;
						var contStartX = leadingSpaces + 1;
						var contEndX = leadingSpaces + cont[2].length;
						(function(u, allR) {
							links.push({
								range: { start: { x: contStartX, y: y }, end: { x: contEndX, y: y } },
								text: u, decorations: { pointerCursor: true },
								activate: function() { if (_metaPressed) postMessage({ type: 'openUrl', url: u }); },
								hover: function() { _hoveredRanges = allR; if (_metaPressed) showPeerUnderlines(allR); },
								leave: function() { _hoveredRanges = null; hidePeerUnderlines(); }
							});
						})(result.url, allRanges);
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

// GPU-accelerated renderer via WebGL. On context loss, retry before giving up —
// GPU can be reclaimed transiently (sleep/wake, another app taking the GPU), and
// a fresh addon instance usually recovers. Permanent fallback to DOM only if
// reinitialization keeps failing.
(function attachWebgl() {
	var retries = 0;
	var maxRetries = 3;
	var retryDelayMs = 800;

	function load() {
		try {
			var webgl = new WebglAddon();
			webgl.onContextLoss(function() {
				webgl.dispose();
				if (retries < maxRetries) {
					retries++;
					setTimeout(load, retryDelayMs);
				}
				// else: give up, xterm.js stays on DOM renderer.
			});
			term.loadAddon(webgl);
			retries = 0;  // successful (re)load resets the counter
		} catch (e) {
			// WebGL unavailable — stay on the DOM renderer.
		}
	}
	load();
})();

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

const terminalPathRegex = /(?:^|[\s("'`\[。、，．：；])(\.{1,2}\/[^\s"'`)\]]+|\/[^\s"'`)\]]+|(?:[A-Za-z0-9_.-]+\/)+[A-Za-z0-9_.-]+)(?::\d+)?(?::\d+)?/g;
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

// Join continuation of a path that spills onto subsequent lines.
// Handles both soft-wrapped lines (term width exceeded) and manually-broken
// output where the next line is indented and starts with path characters.
function buildFullPath(buf, startY, pathStart) {
	var path = pathStart;
	var continuations = [];
	var line = buf.getLine(startY);
	if (!line) return { path: path, continuations: continuations };
	var text = line.translateToString(true);
	var pathEndPos = text.lastIndexOf(pathStart) + pathStart.length;
	var nextLineObj = buf.getLine(startY + 1);
	var isNextWrapped = nextLineObj && nextLineObj.isWrapped;
	// Only bother extending if the path ends at / near the end of the line
	// or the next line is a soft-wrap continuation.
	if (pathEndPos < text.length - 2 && !isNextWrapped) return { path: path, continuations: continuations };
	// Path がすでに .ext で終わっている (= 完成形のファイル名) なら次行に
	// 繋げない。Claude Code の "Wrote N lines to FOO.md\n    1 # ..." のような
	// 出力で line number "1" を pathに連結して "FOO.md1" にしてしまうのを防ぐ。
	// soft-wrap (= 行幅で折り返された場合) は中断されてないので例外。
	if (!isNextWrapped && /\.[A-Za-z0-9]{1,8}(?::\d+)?(?::\d+)?$/.test(pathStart)) {
		return { path: path, continuations: continuations };
	}

	var nextY = startY + 1;
	while (nextY < buf.length) {
		var nextLine = buf.getLine(nextY);
		if (!nextLine) break;
		var nextText = nextLine.translateToString(true);
		var trimmed = nextLine.isWrapped ? nextText : nextText.replace(/^\s+/, '');
		var indent = nextText.length - trimmed.length;
		// Continuation must start with an alphanumeric / _ / ~ / '/' — never '-' or '.'
		// alone (those appear as list markers / ellipses on a fresh line).
		var cont = trimmed.match(/^([A-Za-z0-9_~\/][A-Za-z0-9_\-\.\/~:]*)/);
		if (cont) {
			path += cont[1];
			continuations.push({ y: nextY + 1, startX: indent + 1, endX: indent + cont[1].length });
			if (cont[1].length < trimmed.length) break;
			nextY++;
		} else break;
	}
	return { path: path, continuations: continuations };
}

function ensurePathLinkProvider() {
	if (pathLinkProviderDisposable) return;
	pathLinkProviderDisposable = term.registerLinkProvider({
		provideLinks(y, callback) {
			const buf = term.buffer.active;
			const line = buf.getLine(y - 1);
			if (!line) {
				callback([]);
				return;
			}

			const text = line.translateToString(true);
			const links = [];

			// If this line is a continuation of a path started on the previous line,
			// only surface the continuation link — don't re-match a standalone path
			// on this line (which would create a duplicate, shorter link).
			if (y > 1) {
				const prevLine = buf.getLine(y - 2);
				const isSoftWrapped = line.isWrapped;
				if (prevLine) {
					const prevText = prevLine.translateToString(true);
					terminalPathRegex.lastIndex = 0;
					let prevMatch;
					let lastMatch = null;
					while ((prevMatch = terminalPathRegex.exec(prevText)) !== null) {
						lastMatch = prevMatch;
					}
					if (lastMatch && lastMatch[1]) {
						const prevPath = lastMatch[1];
						const prevStart = lastMatch.index + lastMatch[0].lastIndexOf(prevPath);
						const prevEnd = prevStart + prevPath.length;
						const endsAtEdge = prevEnd >= prevText.length - 1;
						// 拡張子付き完成 path を line-number prefix (= "    1 # ...")
						// と繋いで誤った link にしないためのガード。soft-wrap は除外
						// (term width で強制改行されてるので途中で切れている可能性あり)。
						const prevAlreadyComplete = !isSoftWrapped && /\.[A-Za-z0-9]{1,8}(?::\d+)?(?::\d+)?$/.test(prevPath);
						if ((endsAtEdge || isSoftWrapped) && !prevAlreadyComplete) {
							const trimmed = isSoftWrapped ? text : text.replace(/^\s+/, '');
							const indent = text.length - trimmed.length;
							const cont = trimmed.match(/^([A-Za-z0-9_~\/][A-Za-z0-9_\-\.\/~:]*)/);
							if (cont) {
								const joined = buildFullPath(buf, y - 2, prevPath);
								const peerSx = mapStringIndexToCell(prevLine, prevStart) + 1;
								const peerEx = mapStringIndexToCell(prevLine, prevEnd);
								const peerRange = { y: y - 1, startX: peerSx, endX: peerEx };
								const selfRange = { y: y, startX: indent + 1, endX: indent + cont[1].length };
								const allR = [peerRange, selfRange].concat(joined.continuations.filter(c => c.y !== y));
								const link = {
									range: { start: { x: indent + 1, y: y }, end: { x: indent + cont[1].length, y: y } },
									text: joined.path,
									decorations: { pointerCursor: true },
									hover: () => { showPeerUnderlines(allR); },
									leave: () => { hidePeerUnderlines(); },
									activate: () => { postMessage({ type: 'openPath', path: joined.path }); }
								};
								links.push(link);
								callback(links);
								return;
							}
						}
					}
				}
			}

			terminalPathRegex.lastIndex = 0;
			let match;

			while ((match = terminalPathRegex.exec(text)) !== null) {
				const rawPath = match[1];
				if (!rawPath) continue;
				const startIndex = match.index + match[0].lastIndexOf(rawPath);
				const endIndex = startIndex + rawPath.length;
				const startCell = mapStringIndexToCell(line, startIndex);
				const endCell = mapStringIndexToCell(line, endIndex);

				// Extend across wrapped / indented continuation lines so a long path
				// broken onto multiple rows resolves to a single clickable link.
				const joined = buildFullPath(buf, y - 1, rawPath);
				const selfRange = { y: y, startX: startCell + 1, endX: endCell };
				const allRanges = [selfRange].concat(joined.continuations);

				const link = {
					range: {
						start: { x: startCell + 1, y },
						end: { x: Math.max(startCell + 1, endCell), y }
					},
					text: joined.path,
					decorations: {
						pointerCursor: true
					},
					hover: () => {
						hoveredPathLink = link;
						showPeerUnderlines(allRanges);
					},
					leave: () => {
						hoveredPathLink = null;
						hidePeerUnderlines();
					},
					activate: () => {
						postMessage({ type: 'openPath', path: joined.path });
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
//
// View 切替後の「中身は buffer にあるのに canvas が空表示」事案: xterm.js の
// WebGL renderer は前回 render 時点で hidden だった場合、refresh() だけでは
// 全行を再描画しないことがある (= dirty tracking + GPU state cache の取り合わせ
// の問題)。なのでこの関数では:
//   1. fitAddon.fit() 後に DOM の offsetWidth 読み出しで強制 reflow
//   2. WebGL の textureAtlas を clear
//   3. term.refresh() を 2 回 (即時 + rAF 後) 撃って 1 回目を取りこぼした
//      フレームを保険で補う
// 1 + 2 で殆どの場合は救えるが、まれに rAF までスケジュールが流れない
// パターン (= タブが backgrounded の直後) があるため 3 で最終保険。
window.terminalFit = function() {
	if (!window.term || !window.fitAddon) return null;
	var before = { cols: term.cols, rows: term.rows, baseY: term.buffer.active.baseY, viewportY: term.buffer.active.viewportY, cursorY: term.buffer.active.cursorY };
	fitAddon.fit();
	var dims = fitAddon.proposeDimensions();
	if (!dims || dims.cols < 2 || dims.rows < 1) return null;
	var after = { cols: term.cols, rows: term.rows, baseY: term.buffer.active.baseY, viewportY: term.buffer.active.viewportY, cursorY: term.buffer.active.cursorY };
	_lastFitCols = dims.cols;
	_lastFitRows = dims.rows;
	if (term._core && term._core.viewport) {
		term._core.viewport.syncScrollArea();
	}
	// Force browser layout (= ensures canvas size is finalized before redraw).
	if (term.element) { void term.element.offsetWidth; }
	if (term.clearTextureAtlas) term.clearTextureAtlas();
	term.refresh(0, term.rows - 1);
	// rAF 後の二度撃ち。WebGL renderer の dirty-row tracking が
	// hidden→visible 遷移で取りこぼすケースの最終保険。
	requestAnimationFrame(function() {
		if (term.clearTextureAtlas) term.clearTextureAtlas();
		term.refresh(0, term.rows - 1);
	});
	term.scrollToBottom();
	var final_ = { baseY: term.buffer.active.baseY, viewportY: term.buffer.active.viewportY };
	postMessage({ type: 'debug', message: '[terminalFit] before=' + JSON.stringify(before) + ' proposed=' + JSON.stringify(dims) + ' after=' + JSON.stringify(after) + ' final=' + JSON.stringify(final_) });
	return { cols: dims.cols, rows: dims.rows };
};

// SerializeAddon: ターミナル状態の serialize/restore
window.terminalSerialize = function() {
	if (!serializeAddon) return null;
	return serializeAddon.serialize({ scrollback: 10000 });
};

window.terminalRestore = function(data) {
	if (!term || !data) return;
	term.reset();
	term.write(data, function() {
		term.scrollToBottom();
	});
};

// Hide/reveal terminal screen during resize to prevent visible redraw scroll
window.terminalSetResizing = function(hide) {
	var screen = term.element && term.element.querySelector('.xterm-screen');
	if (!screen) return;
	screen.style.transition = hide ? 'none' : 'opacity 0.15s';
	screen.style.opacity = hide ? '0' : '1';
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

window.terminalSetFontSize = function(size) {
	const clamped = Math.max(8, Math.min(28, size));
	if (term.options.fontSize === clamped) return;
	term.options.fontSize = clamped;
	// 反映には refit が必要 (font 変わると 1 文字あたりの cell 寸法が変わる)
	if (window.terminalFit) window.terminalFit();
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

// ResizeObserver — JS 内で即座に reflow (Swift IPC round trip を排除)
var _lastFitCols = 0, _lastFitRows = 0;
var _ptyResizeTimeout = null;
var _fitDebounceTimeout = null;
var _suppressPtyResize = false;
function doFit() {
	if (!window.term || !window.fitAddon) return;
	var dims = fitAddon.proposeDimensions();
	if (!dims || dims.cols < 2 || dims.rows < 1) return;
	if (dims.cols === _lastFitCols && dims.rows === _lastFitRows) return;
	var buf = term.buffer.active;
	var wasAtBottom = buf.viewportY >= buf.baseY;
	var viewport = term.element && term.element.querySelector('.xterm-viewport');
	var screen = term.element && term.element.querySelector('.xterm-screen');
	if (viewport) viewport.style.visibility = 'hidden';
	if (screen) screen.style.visibility = 'hidden';
	term.resize(dims.cols, dims.rows);
	if (wasAtBottom) term.scrollToBottom();
	requestAnimationFrame(function() {
		if (viewport) viewport.style.visibility = '';
		if (screen) screen.style.visibility = '';
	});
	_lastFitCols = dims.cols;
	_lastFitRows = dims.rows;
	if (!_suppressPtyResize) {
		if (_ptyResizeTimeout) clearTimeout(_ptyResizeTimeout);
		_ptyResizeTimeout = setTimeout(function() {
			postMessage({ type: 'resize', cols: dims.cols, rows: dims.rows });
		}, 150);
	}
}
// ResizeObserver は高頻度で発火するので 16ms (1 frame) debounce
const resizeObserver = new ResizeObserver(function() {
	if (_fitDebounceTimeout) clearTimeout(_fitDebounceTimeout);
	_fitDebounceTimeout = setTimeout(doFit, 16);
});
resizeObserver.observe(terminalContainer);

// Title change
term.onTitleChange(function(title) {
	postMessage({ type: 'title', title: title });
});

// Bell — intentionally not forwarded. Terminal output often contains \x07 (bell)
// from prior sessions' replay buffer, which would make the app beep multiple
// times on attach. Modern terminal UX keeps this off by default.

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
