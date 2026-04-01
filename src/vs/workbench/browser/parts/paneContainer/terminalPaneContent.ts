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

	constructor(
		@ITerminalService private readonly terminalService: ITerminalService,
	) {
		super();
	}

	render(container: HTMLElement): void {
		if (this._isRendered) {
			return;
		}
		this._isRendered = true;

		this.terminalService.createTerminal({ config: { env: { DOCK_CODE_SESSION: '1' } } }).then(instance => {
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
