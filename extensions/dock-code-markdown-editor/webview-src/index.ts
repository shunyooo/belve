/*---------------------------------------------------------------------------------------------
 *  Copyright (c) dock-code contributors. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Crepe, CrepeFeature } from '@milkdown/crepe';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame.css';
import './style.css';

declare function acquireVsCodeApi(): {
	postMessage(msg: unknown): void;
	getState(): unknown;
	setState(state: unknown): void;
};

const vscode = acquireVsCodeApi();

let crepe: Crepe | undefined;
let isExternalUpdate = false;
let debounceTimer: ReturnType<typeof setTimeout> | undefined;

async function initEditor(content: string): Promise<void> {
	const root = document.getElementById('editor');
	if (!root) {
		return;
	}

	crepe = new Crepe({
		root,
		defaultValue: content,
		features: {
			[CrepeFeature.BlockEdit]: false,
			[CrepeFeature.TopBar]: false,
			[CrepeFeature.Toolbar]: false,
			[CrepeFeature.Placeholder]: false,
		},
	});

	crepe.on((listener) => {
		return listener
			.markdownUpdated((_ctx, markdown, prevMarkdown) => {
				if (isExternalUpdate) {
					return;
				}
				if (markdown === prevMarkdown) {
					return;
				}

				// Debounce edits to avoid flooding the extension host
				if (debounceTimer) {
					clearTimeout(debounceTimer);
				}
				debounceTimer = setTimeout(() => {
					vscode.postMessage({ type: 'edit', content: markdown });
				}, 300);
			});
	});

	await crepe.create();
}

// Handle messages from the extension
window.addEventListener('message', async (event) => {
	const msg = event.data;

	switch (msg.type) {
		case 'init': {
			await initEditor(msg.content);
			break;
		}

		case 'update': {
			if (!crepe) {
				break;
			}
			// External change: rebuild editor content
			isExternalUpdate = true;
			try {
				// Destroy and recreate with new content
				// TODO: Use Milkdown's internal API for incremental updates
				// when available, instead of full recreation
				const root = document.getElementById('editor');
				if (root) {
					await crepe.destroy();
					crepe = undefined;
					root.innerHTML = '';
					await initEditor(msg.content);
				}
			} finally {
				isExternalUpdate = false;
			}
			break;
		}
	}
});

// Signal to the extension that the webview is ready
vscode.postMessage({ type: 'ready' });
