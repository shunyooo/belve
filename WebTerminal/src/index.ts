import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { WebLinksAddon } from '@xterm/addon-web-links';
import '@xterm/xterm/css/xterm.css';

const term = new Terminal({
	cursorBlink: true,
	fontSize: 13,
	fontFamily: "'SF Mono', Menlo, Monaco, 'Courier New', monospace",
	theme: {
		background: '#1a1a1f',
		foreground: '#e0e3eb',
		cursor: '#e0e3eb',
		selectionBackground: '#ffffff26',
		black: '#1a1a1f',
		brightBlack: '#555555',
		red: '#d9595f',
		brightRed: '#e06c75',
		green: '#59d98e',
		brightGreen: '#98c379',
		yellow: '#d9b359',
		brightYellow: '#e5c07b',
		blue: '#73ade8',
		brightBlue: '#61afef',
		magenta: '#c678dd',
		brightMagenta: '#c678dd',
		cyan: '#56b6c2',
		brightCyan: '#56b6c2',
		white: '#e0e3eb',
		brightWhite: '#ffffff',
	},
});

const fitAddon = new FitAddon();
term.loadAddon(fitAddon);
term.loadAddon(new WebLinksAddon());

term.open(document.getElementById('terminal')!);
fitAddon.fit();

// Resize observer
const resizeObserver = new ResizeObserver(() => {
	fitAddon.fit();
	// Notify Swift of new size
	(window as any).webkit?.messageHandlers?.terminalHandler?.postMessage({
		type: 'resize',
		cols: term.cols,
		rows: term.rows,
	});
});
resizeObserver.observe(document.getElementById('terminal')!);

// User input → Swift
term.onData((data: string) => {
	(window as any).webkit?.messageHandlers?.terminalHandler?.postMessage({
		type: 'input',
		data: data,
	});
});

// Swift → terminal output
(window as any).terminalWrite = (data: string) => {
	term.write(data);
};

// Swift → resize
(window as any).terminalFit = () => {
	fitAddon.fit();
};

// Signal ready
(window as any).webkit?.messageHandlers?.terminalHandler?.postMessage({
	type: 'ready',
});
