/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Disposable } from '../../../../base/common/lifecycle.js';
import { IPaneContent } from './paneView.js';
import { ITerminalService, type ITerminalInstance } from '../../../contrib/terminal/browser/terminal.js'; // eslint-disable-line local/code-import-patterns

export class TerminalPaneContent extends Disposable implements IPaneContent {
	readonly type = 'terminal';
	private instance: ITerminalInstance | undefined;
	private _isRendered = false;
	private _lastWidth = 0;
	private _lastHeight = 0;
	private _paneId: string = '';

	constructor(
		@ITerminalService private readonly terminalService: ITerminalService,
	) {
		super();
	}

	setPaneId(paneId: string): void {
		this._paneId = paneId;
	}

	render(container: HTMLElement): void {
		if (this._isRendered) {
			return;
		}
		this._isRendered = true;

		// Wrap shell in tmux for session persistence across reconnections.
		// Uses pane ID for stable session name so re-attach works after restart.
		// Falls back to plain $SHELL if tmux is not installed.
		const tmuxSession = `dc-${this._paneId.substring(0, 8)}`;
		const tmuxCmd = `command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s ${tmuxSession} || exec $SHELL`;

		this.terminalService.createTerminal({
			config: {
				executable: '/bin/sh',
				args: ['-c', tmuxCmd],
				env: {
					DOCK_CODE_SESSION: '1',
					DOCK_CODE_PANE_ID: this._paneId,
				}
			}
		}).then(instance => {
			this.instance = instance;
			instance.attachToElement(container);
			instance.setVisible(true);
			// Apply pending layout after terminal is attached
			if (this._lastWidth > 0 && this._lastHeight > 0) {
				instance.layout({ width: this._lastWidth, height: this._lastHeight });
			}
		}, err => {
			console.error('[TerminalPaneContent] createTerminal failed:', err);
		});
	}

	layout(width: number, height: number): void {
		this._lastWidth = width;
		this._lastHeight = height;
		this.instance?.layout({ width, height });
	}

	focus(): void {
		this.instance?.focus();
	}

	toJSON(): object {
		return { type: 'terminal' };
	}

	override dispose(): void {
		if (this.instance) {
			this.instance.detachFromElement();
			this.instance.dispose();
		}
		super.dispose();
	}
}
