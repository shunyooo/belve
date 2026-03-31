/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Disposable } from '../../../../base/common/lifecycle.js';
import { IPaneContent } from './paneView.js';
import { ITerminalService } from '../../../contrib/terminal/browser/terminal.js';
import type { ITerminalInstance } from '../../../contrib/terminal/browser/terminal.js';

export class TerminalPaneContent extends Disposable implements IPaneContent {
	readonly type = 'terminal';
	private instance: ITerminalInstance | undefined;
	private _isRendered = false;

	constructor(
		private readonly terminalService: ITerminalService,
	) {
		super();
	}

	render(container: HTMLElement): void {
		if (this._isRendered) {
			return;
		}
		this._isRendered = true;

		this.terminalService.createTerminal({}).then(instance => {
			this.instance = instance;
			instance.attachToElement(container);
			instance.setVisible(true);
		});
	}

	layout(width: number, height: number): void {
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
