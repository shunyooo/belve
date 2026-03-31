/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import './media/paneContainer.css';
import { Part } from '../../part.js';
import { Parts, IWorkbenchLayoutService } from '../../../services/layout/browser/layoutService.js';
import { IThemeService } from '../../../../platform/theme/common/themeService.js';
import { IStorageService, StorageScope, StorageTarget } from '../../../../platform/storage/common/storage.js';
import { IInstantiationService } from '../../../../platform/instantiation/common/instantiation.js';
import { $ } from '../../../../base/browser/dom.js';
import { SerializableGrid, Direction, Sizing } from '../../../../base/browser/ui/grid/grid.js';
import { PaneView, IPaneContent } from './paneView.js';
import { TerminalPaneContent } from './terminalPaneContent.js';
import { ITerminalService } from '../../../contrib/terminal/browser/terminal.js';
import { DisposableStore } from '../../../../base/common/lifecycle.js';
import { contrastBorder } from '../../../../platform/theme/common/colorRegistry.js';
import { ACTIVITY_BAR_BACKGROUND, ACTIVITY_BAR_BORDER } from '../../../common/theme.js';
import { assertReturnsDefined } from '../../../../base/common/types.js';

const PANE_CONTAINER_STATE_KEY = 'dockcode.paneContainer.state';

export class PaneContainerPart extends Part {

	static readonly ID = 'workbench.parts.panecontainer';

	//#region IView

	readonly minimumWidth = 200;
	readonly maximumWidth = 800;
	readonly minimumHeight = 0;
	readonly maximumHeight = Number.POSITIVE_INFINITY;

	//#endregion

	private grid: SerializableGrid<PaneView> | undefined;
	private gridElement: HTMLElement | undefined;
	private readonly paneDisposables = this._register(new DisposableStore());
	private readonly panes: PaneView[] = [];

	constructor(
		@IWorkbenchLayoutService layoutService: IWorkbenchLayoutService,
		@IThemeService themeService: IThemeService,
		@IStorageService private readonly storageService2: IStorageService,
		@IInstantiationService private readonly instantiationService: IInstantiationService,
	) {
		super(Parts.PANECONTAINER_PART, { hasTitle: false }, themeService, storageService2, layoutService);
	}

	protected override createContentArea(parent: HTMLElement): HTMLElement {
		this.element = parent;
		this.element.classList.add('pane-container-part');

		this.gridElement = $('div.pane-container-grid');
		parent.appendChild(this.gridElement);

		this.initGrid();

		return this.gridElement;
	}

	private initGrid(): void {
		const state = this.storageService2.get(PANE_CONTAINER_STATE_KEY, StorageScope.WORKSPACE);
		if (state) {
			try {
				const parsed = JSON.parse(state);
				this.grid = SerializableGrid.deserialize(parsed.grid, {
					fromJSON: (data: { contentType?: string }) => {
						return this.createPaneFromType(data.contentType ?? 'terminal');
					}
				});
			} catch {
				// Fallback to fresh grid
				this.grid = undefined;
			}
		}

		if (!this.grid) {
			const initialPane = this.createPaneFromType('terminal');
			this.grid = new SerializableGrid(initialPane);
		}

		if (this.gridElement) {
			this.gridElement.appendChild(this.grid.element);
		}
	}

	private createPaneFromType(type: string): PaneView {
		const pane = new PaneView();
		this.panes.push(pane);

		const disposables = new DisposableStore();
		this.paneDisposables.add(disposables);

		disposables.add(pane.onDidRequestClose(() => this.closePane(pane)));
		disposables.add(pane.onDidRequestSplitDown(() => this.splitPane(pane, Direction.Down)));
		disposables.add(pane.onDidRequestSplitRight(() => this.splitPane(pane, Direction.Right)));

		const content = this.createContent(type);
		if (content) {
			pane.setContent(content);
		}

		return pane;
	}

	private createContent(type: string): IPaneContent | undefined {
		switch (type) {
			case 'terminal': {
				const terminalService = this.instantiationService.invokeFunction(accessor => accessor.get(ITerminalService));
				return new TerminalPaneContent(terminalService);
			}
			default:
				return undefined;
		}
	}

	splitPane(referencePane: PaneView, direction: Direction): PaneView {
		const newPane = this.createPaneFromType('terminal');
		if (this.grid) {
			this.grid.addView(newPane, Sizing.Distribute, referencePane, direction);
		}
		return newPane;
	}

	closePane(pane: PaneView): void {
		if (!this.grid) {
			return;
		}

		const index = this.panes.indexOf(pane);
		if (index === -1) {
			return;
		}

		// Don't close the last pane
		if (this.panes.length <= 1) {
			return;
		}

		this.grid.removeView(pane, Sizing.Distribute);
		this.panes.splice(index, 1);
		pane.dispose();
	}

	override updateStyles(): void {
		super.updateStyles();

		const container = assertReturnsDefined(this.getContainer());
		const background = this.getColor(ACTIVITY_BAR_BACKGROUND) || '';
		container.style.backgroundColor = background;

		const borderColor = this.getColor(ACTIVITY_BAR_BORDER) || this.getColor(contrastBorder) || '';
		container.classList.toggle('bordered', !!borderColor);
		container.style.borderRightColor = borderColor || '';
	}

	override layout(width: number, height: number, top: number, left: number): void {
		super.layout(width, height, top, left);

		if (this.grid && width > 0 && height > 0) {
			this.grid.layout(width, height, top, left);
		}
	}

	protected override saveState(): void {
		if (this.grid) {
			const state = {
				grid: this.grid.serialize()
			};
			this.storageService2.store(
				PANE_CONTAINER_STATE_KEY,
				JSON.stringify(state),
				StorageScope.WORKSPACE,
				StorageTarget.MACHINE
			);
		}
		super.saveState();
	}

	focus(): void {
		if (this.panes.length > 0) {
			this.panes[0].focus();
		}
	}

	toJSON(): object {
		return {
			type: Parts.PANECONTAINER_PART
		};
	}
}
