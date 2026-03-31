/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Disposable, IDisposable } from '../../../../base/common/lifecycle.js';
import { Emitter, Event } from '../../../../base/common/event.js';
import { $, append, clearNode } from '../../../../base/browser/dom.js';
import { IViewSize } from '../../../../base/browser/ui/grid/grid.js';
import { ISerializableView } from '../../../../base/browser/ui/grid/grid.js';

export interface IPaneContent extends IDisposable {
	readonly type: string;
	render(container: HTMLElement): void;
	layout(width: number, height: number): void;
	focus(): void;
	toJSON(): object;
}

export interface IPaneViewState {
	type: string;
	contentState: object;
}

export class PaneView extends Disposable implements ISerializableView {

	readonly element: HTMLElement;
	readonly minimumWidth = 100;
	readonly maximumWidth = Number.POSITIVE_INFINITY;
	readonly minimumHeight = 50;
	readonly maximumHeight = Number.POSITIVE_INFINITY;

	private readonly _onDidChange = this._register(new Emitter<IViewSize | undefined>());
	readonly onDidChange: Event<IViewSize | undefined> = this._onDidChange.event;

	private readonly headerElement: HTMLElement;
	private readonly contentElement: HTMLElement;
	private _content: IPaneContent | undefined;
	private _width = 0;
	private _height = 0;

	private readonly _onDidRequestClose = this._register(new Emitter<void>());
	readonly onDidRequestClose: Event<void> = this._onDidRequestClose.event;

	private readonly _onDidRequestSplitDown = this._register(new Emitter<void>());
	readonly onDidRequestSplitDown: Event<void> = this._onDidRequestSplitDown.event;

	private readonly _onDidRequestSplitRight = this._register(new Emitter<void>());
	readonly onDidRequestSplitRight: Event<void> = this._onDidRequestSplitRight.event;

	constructor() {
		super();

		this.element = $('.pane-view');

		this.headerElement = append(this.element, $('.pane-view-header'));
		this.contentElement = append(this.element, $('.pane-view-content'));

		this.createHeader();
	}

	private createHeader(): void {
		clearNode(this.headerElement);

		const title = append(this.headerElement, $('span.pane-view-title'));
		title.textContent = this._content?.type ?? 'Empty';

		const actions = append(this.headerElement, $('.pane-view-actions'));

		const splitDownBtn = append(actions, $('a.action-label.codicon.codicon-split-vertical'));
		splitDownBtn.title = 'Split Down';
		splitDownBtn.tabIndex = 0;
		this._register({ dispose: () => splitDownBtn.removeEventListener('click', splitDownHandler) });
		const splitDownHandler = () => this._onDidRequestSplitDown.fire();
		splitDownBtn.addEventListener('click', splitDownHandler);

		const splitRightBtn = append(actions, $('a.action-label.codicon.codicon-split-horizontal'));
		splitRightBtn.title = 'Split Right';
		splitRightBtn.tabIndex = 0;
		this._register({ dispose: () => splitRightBtn.removeEventListener('click', splitRightHandler) });
		const splitRightHandler = () => this._onDidRequestSplitRight.fire();
		splitRightBtn.addEventListener('click', splitRightHandler);

		const closeBtn = append(actions, $('a.action-label.codicon.codicon-close'));
		closeBtn.title = 'Close';
		closeBtn.tabIndex = 0;
		this._register({ dispose: () => closeBtn.removeEventListener('click', closeHandler) });
		const closeHandler = () => this._onDidRequestClose.fire();
		closeBtn.addEventListener('click', closeHandler);
	}

	get content(): IPaneContent | undefined {
		return this._content;
	}

	setContent(content: IPaneContent): void {
		if (this._content) {
			this._content.dispose();
		}
		this._content = content;
		clearNode(this.contentElement);
		content.render(this.contentElement);
		this.createHeader();

		if (this._width > 0 && this._height > 0) {
			const headerHeight = this.headerElement.offsetHeight || 24;
			content.layout(this._width, this._height - headerHeight);
		}
	}

	layout(width: number, height: number, _top: number, _left: number): void {
		this._width = width;
		this._height = height;

		this.element.style.width = `${width}px`;
		this.element.style.height = `${height}px`;

		if (this._content) {
			const headerHeight = this.headerElement.offsetHeight || 24;
			this._content.layout(width, height - headerHeight);
		}
	}

	focus(): void {
		this._content?.focus();
	}

	toJSON(): object {
		return {
			type: 'paneView',
			contentType: this._content?.type ?? 'empty',
			contentState: this._content?.toJSON() ?? {}
		};
	}

	override dispose(): void {
		this._content?.dispose();
		super.dispose();
	}
}
