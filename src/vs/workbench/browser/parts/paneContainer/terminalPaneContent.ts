/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Disposable } from '../../../../base/common/lifecycle.js';
import { clearNode } from '../../../../base/browser/dom.js';
import { IPaneContent } from './paneView.js';
import { ITerminalService, type ITerminalInstance } from '../../../contrib/terminal/browser/terminal.js'; // eslint-disable-line local/code-import-patterns

export class TerminalPaneContent extends Disposable implements IPaneContent {
	readonly type = 'terminal';
	private instance: ITerminalInstance | undefined;
	private _isRendered = false;
	private _attached = false;
	private _lastWidth = 0;
	private _lastHeight = 0;
	private _paneId: string = '';
	private _container: HTMLElement | undefined;
	private _attachPollTimer: ReturnType<typeof setInterval> | undefined;
	private _disposing = false;
	private _retryCount = 0;
	private static readonly MAX_RETRIES = 3;

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
		this._container = container;

		console.warn(`[TerminalPaneContent] render() called, paneId=${this._paneId}, container=${container.clientWidth}x${container.clientHeight}`);
		this._createTerminalInstance();
	}

	private _createTerminalInstance(): void {
		// Wrap shell in tmux for session persistence across reconnections.
		// Uses pane ID for stable session name so re-attach works after restart.
		// Falls back to default shell if tmux is not installed.
		// Uses ${SHELL:-/bin/bash} to handle containers where $SHELL is unset.
		const tmuxSession = `dc-${this._paneId.substring(0, 8)}`;
		const tmuxCmd = `command -v tmux >/dev/null 2>&1 && exec tmux new-session -A -s ${tmuxSession} || exec "\${SHELL:-/bin/bash}" -l`;

		console.warn(`[TerminalPaneContent] calling createTerminal... (retry=${this._retryCount})`);
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
			if (this._disposing) {
				instance.dispose();
				return;
			}
			console.warn(`[TerminalPaneContent] createTerminal resolved, instance id=${instance.instanceId}`);
			this.instance = instance;
			this._attached = false;

			// Re-create terminal if it's disposed unexpectedly (e.g. during
			// remote connection transitions like DevContainer setup).
			this._register(instance.onDisposed(() => {
				console.warn(`[TerminalPaneContent] instance DISPOSED, paneId=${this._paneId}, instanceId=${instance.instanceId}`);
				if (!this._disposing && this._retryCount < TerminalPaneContent.MAX_RETRIES) {
					this._retryCount++;
					this._attached = false;
					this.instance = undefined;
					// Clear the container so the new terminal can attach fresh
					if (this._container) {
						clearNode(this._container);
					}
					console.warn(`[TerminalPaneContent] scheduling retry ${this._retryCount}/${TerminalPaneContent.MAX_RETRIES} in 2s...`);
					setTimeout(() => {
						if (!this._disposing) {
							this._createTerminalInstance();
						}
					}, 2000);
				}
			}));
			this._register(instance.onExit((exitInfo) => {
				console.warn(`[TerminalPaneContent] instance EXIT, paneId=${this._paneId}, instanceId=${instance.instanceId}, exitInfo=${JSON.stringify(exitInfo)}`);
			}));

			this._tryAttach();
		}, err => {
			console.error('[TerminalPaneContent] createTerminal failed:', err);
		});
	}

	private _tryAttach(): void {
		if (this._attached || !this.instance || !this._container) {
			return;
		}

		const cw = this._container.clientWidth;
		const ch = this._container.clientHeight;
		console.warn(`[TerminalPaneContent] _tryAttach: clientWidth=${cw}, clientHeight=${ch}, lastWidth=${this._lastWidth}, lastHeight=${this._lastHeight}`);

		if (cw === 0 || ch === 0) {
			this._startAttachPoll();
			return;
		}

		this._stopAttachPoll();
		this._attached = true;
		console.warn(`[TerminalPaneContent] attaching to element...`);
		this.instance.attachToElement(this._container);
		this.instance.setVisible(true);
		if (this._lastWidth > 0 && this._lastHeight > 0) {
			this.instance.layout({ width: this._lastWidth, height: this._lastHeight });
		}
		console.warn(`[TerminalPaneContent] attach complete`);
	}

	private _startAttachPoll(): void {
		if (this._attachPollTimer !== undefined) {
			return;
		}
		console.warn(`[TerminalPaneContent] starting attach poll (container not visible yet)`);
		this._attachPollTimer = setInterval(() => this._tryAttach(), 500);
	}

	private _stopAttachPoll(): void {
		if (this._attachPollTimer !== undefined) {
			clearInterval(this._attachPollTimer);
			this._attachPollTimer = undefined;
		}
	}

	layout(width: number, height: number): void {
		this._lastWidth = width;
		this._lastHeight = height;
		if (!this._attached) {
			this._tryAttach();
		} else {
			this.instance?.layout({ width, height });
		}
	}

	focus(): void {
		if (!this._attached) {
			this._tryAttach();
		}
		this.instance?.focus();
	}

	toJSON(): object {
		return { type: 'terminal' };
	}

	override dispose(): void {
		this._disposing = true;
		this._stopAttachPoll();
		if (this.instance) {
			this.instance.detachFromElement();
			this.instance.dispose();
		}
		super.dispose();
	}
}
