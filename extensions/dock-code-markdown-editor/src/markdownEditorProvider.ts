/*---------------------------------------------------------------------------------------------
 *  Copyright (c) dock-code contributors. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/
import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

export class MarkdownEditorProvider implements vscode.CustomTextEditorProvider {

	private static readonly viewType = 'dock-code.markdownWysiwyg';

	// Cache inlined assets to avoid repeated file reads
	private _cachedJs: string | undefined;
	private _cachedCss: string | undefined;

	public static register(context: vscode.ExtensionContext): vscode.Disposable {
		return vscode.window.registerCustomEditorProvider(
			MarkdownEditorProvider.viewType,
			new MarkdownEditorProvider(context),
			{
				webviewOptions: {
					retainContextWhenHidden: true,
					enableFindWidget: true,
				},
			}
		);
	}

	constructor(private readonly context: vscode.ExtensionContext) { }

	public async resolveCustomTextEditor(
		document: vscode.TextDocument,
		webviewPanel: vscode.WebviewPanel,
		_token: vscode.CancellationToken
	): Promise<void> {
		const webview = webviewPanel.webview;
		webview.options = {
			enableScripts: true,
		};

		const config = vscode.workspace.getConfiguration('markdownEditor');
		const styleConfig = {
			fontSize: config.get<number>('fontSize', 14),
			lineHeight: config.get<number>('lineHeight', 1.6),
			h1FontSize: config.get<number>('h1FontSize', 24),
			h2FontSize: config.get<number>('h2FontSize', 20),
			h3FontSize: config.get<number>('h3FontSize', 17),
		};

		webview.html = this._getHtmlForWebview(styleConfig);

		// Send initial content once webview is ready
		const readyDisposable = webview.onDidReceiveMessage(msg => {
			if (msg.type === 'ready') {
				webview.postMessage({
					type: 'init',
					content: document.getText(),
				});
				readyDisposable.dispose();
			}
		});

		// --- Bidirectional sync ---

		// Sync guard: prevent update loops
		let isUpdatingFromWebview = false;
		let debounceTimer: ReturnType<typeof setTimeout> | undefined;

		// Webview → TextDocument
		const messageDisposable = webview.onDidReceiveMessage(msg => {
			if (msg.type === 'edit' && typeof msg.content === 'string') {
				// Skip if content is identical to current document
				if (msg.content === document.getText()) {
					return;
				}

				isUpdatingFromWebview = true;

				const edit = new vscode.WorkspaceEdit();
				edit.replace(
					document.uri,
					new vscode.Range(0, 0, document.lineCount, 0),
					msg.content
				);

				vscode.workspace.applyEdit(edit).then(() => {
					isUpdatingFromWebview = false;
				}, () => {
					isUpdatingFromWebview = false;
				});
			}
		});

		// TextDocument → Webview (external changes: git, other editors, etc.)
		const changeDisposable = vscode.workspace.onDidChangeTextDocument(e => {
			if (e.document.uri.toString() !== document.uri.toString()) {
				return;
			}
			if (isUpdatingFromWebview) {
				return;
			}

			// Debounce rapid external changes
			if (debounceTimer) {
				clearTimeout(debounceTimer);
			}
			debounceTimer = setTimeout(() => {
				webview.postMessage({
					type: 'update',
					content: document.getText(),
				});
			}, 100);
		});

		webviewPanel.onDidDispose(() => {
			readyDisposable.dispose();
			messageDisposable.dispose();
			changeDisposable.dispose();
			if (debounceTimer) {
				clearTimeout(debounceTimer);
			}
		});
	}

	private _getInlinedJs(): string {
		if (!this._cachedJs) {
			const jsPath = path.join(this.context.extensionPath, 'media', 'index.js');
			this._cachedJs = fs.readFileSync(jsPath, 'utf8');
		}
		return this._cachedJs;
	}

	private _getInlinedCss(): string {
		if (!this._cachedCss) {
			const cssPath = path.join(this.context.extensionPath, 'media', 'index.css');
			this._cachedCss = fs.readFileSync(cssPath, 'utf8');
		}
		return this._cachedCss;
	}

	private _getHtmlForWebview(s: { fontSize: number; lineHeight: number; h1FontSize: number; h2FontSize: number; h3FontSize: number }): string {
		const inlinedCss = this._getInlinedCss();
		const inlinedJs = this._getInlinedJs();

		return /* html */`<!DOCTYPE html>
<html lang="en">
<head>
	<meta charset="UTF-8">
	<meta name="viewport" content="width=device-width, initial-scale=1.0">
	<style>${inlinedCss}</style>
	<style>
		.milkdown { font-size: ${s.fontSize}px !important; line-height: ${s.lineHeight} !important; }
		.milkdown .ProseMirror p { font-size: ${s.fontSize}px !important; line-height: ${s.lineHeight} !important; }
		.milkdown .ProseMirror h1 { font-size: ${s.h1FontSize}px !important; }
		.milkdown .ProseMirror h2 { font-size: ${s.h2FontSize}px !important; }
		.milkdown .ProseMirror h3 { font-size: ${s.h3FontSize}px !important; }
		.milkdown .ProseMirror h4,
		.milkdown .ProseMirror h5,
		.milkdown .ProseMirror h6 { font-size: ${s.fontSize}px !important; }
	</style>
	<title>Markdown Editor</title>
</head>
<body>
	<div id="editor"></div>
	<script>${inlinedJs}</script>
</body>
</html>`;
	}
}

function getNonce(): string {
	let text = '';
	const possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
	for (let i = 0; i < 64; i++) {
		text += possible.charAt(Math.floor(Math.random() * possible.length));
	}
	return text;
}
