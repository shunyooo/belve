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
import { DisposableStore } from '../../../../base/common/lifecycle.js';
import { contrastBorder } from '../../../../platform/theme/common/colorRegistry.js';
import { ACTIVITY_BAR_BACKGROUND, ACTIVITY_BAR_BORDER } from '../../../common/theme.js';
import { assertReturnsDefined } from '../../../../base/common/types.js';
import { Emitter, Event } from '../../../../base/common/event.js';
import { PaneDirection } from '../../../services/paneContainer/common/paneContainerService.js';
import { IProjectMainService } from '../../../../platform/projects/common/projects.js';
const PANE_CONTAINER_STATE_KEY = 'dockcode.paneContainer.state';

export class PaneContainerPart extends Part {

	static readonly ID = 'workbench.parts.panecontainer';

	//#region IView

	readonly minimumWidth = 100;
	readonly maximumWidth = Number.POSITIVE_INFINITY;
	readonly minimumHeight = 0;
	readonly maximumHeight = Number.POSITIVE_INFINITY;

	//#endregion

	private grid: SerializableGrid<PaneView> | undefined;
	private gridElement: HTMLElement | undefined;
	private readonly paneDisposables = this._register(new DisposableStore());
	private readonly panes: PaneView[] = [];
	private _activePane: PaneView | undefined;

	private readonly _onDidChangeActivePane = this._register(new Emitter<PaneView | undefined>());
	readonly onDidChangeActivePane: Event<PaneView | undefined> = this._onDidChangeActivePane.event;

	constructor(
		@IWorkbenchLayoutService layoutService: IWorkbenchLayoutService,
		@IThemeService themeService: IThemeService,
		@IStorageService private readonly storageService2: IStorageService,
		@IInstantiationService private readonly instantiationService: IInstantiationService,
		@IProjectMainService private readonly projectMainService: IProjectMainService,
	) {
		super(Parts.PANECONTAINER_PART, { hasTitle: false }, themeService, storageService2, layoutService);

		// Focus PaneContainer when requested via notification click
		this._register(this.projectMainService.onDidRequestPaneContainerFocus(() => {
			this.focus();
		}));
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

		// Track active pane on focus (click, keyboard, etc.)
		disposables.add(pane.onDidFocus(() => this.setActivePane(pane)));

		const content = this.createContent(type);
		if (content) {
			pane.setContent(content);
		}

		return pane;
	}

	private createContent(type: string): IPaneContent | undefined {
		switch (type) {
			case 'terminal':
				return this.instantiationService.createInstance(TerminalPaneContent);
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

		// Update active pane if the closed pane was active
		if (this._activePane === pane) {
			this._activePane = this.panes[Math.min(index, this.panes.length - 1)];
			this._onDidChangeActivePane.fire(this._activePane);
		}

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

	get activePane(): PaneView | undefined {
		return this._activePane ?? this.panes[0];
	}

	private setActivePane(pane: PaneView): void {
		if (this._activePane === pane) {
			return;
		}
		this._activePane = pane;
		this._onDidChangeActivePane.fire(pane);
	}

	focus(): void {
		const pane = this.activePane;
		if (pane) {
			this.setActivePane(pane);
			pane.focus();
		}
	}

	//#region Pane Navigation

	/**
	 * Focus a neighboring pane in the given direction.
	 * Returns true if a neighbor was found and focused, false if at the edge.
	 */
	focusPaneInDirection(direction: PaneDirection): boolean {
		if (!this.grid || !this.activePane) {
			return false;
		}
		try {
			const neighbors = this.grid.getNeighborViews(this.activePane, direction as unknown as Direction);
			if (neighbors.length > 0) {
				this.setActivePane(neighbors[0]);
				neighbors[0].focus();
				return true;
			}
		} catch {
			// getNeighborViews can throw before first layout
		}
		return false;
	}

	splitActivePane(direction: PaneDirection): void {
		const pane = this.activePane;
		if (pane) {
			const newPane = this.splitPane(pane, direction as unknown as Direction);
			this.setActivePane(newPane);
			newPane.focus();
		}
	}

	closeActivePane(): void {
		const pane = this.activePane;
		if (!pane) {
			return;
		}
		// Find next pane to focus before closing
		const index = this.panes.indexOf(pane);
		const nextPane = this.panes[index + 1] ?? this.panes[index - 1];
		this.closePane(pane);
		if (nextPane) {
			this.setActivePane(nextPane);
			nextPane.focus();
		}
	}

	private _zoomedPane: PaneView | undefined;

	togglePaneZoom(): void {
		if (!this.grid || !this.activePane) {
			return;
		}
		if (this._zoomedPane) {
			this.grid.expandView(this._zoomedPane);
			this.grid.distributeViewSizes();
			this._zoomedPane = undefined;
		} else {
			this._zoomedPane = this.activePane;
			this.grid.maximizeView(this._zoomedPane);
		}
	}

	focusNextPane(): void {
		if (this.panes.length <= 1) { return; }
		const idx = this._activePane ? this.panes.indexOf(this._activePane) : -1;
		const next = this.panes[(idx + 1) % this.panes.length];
		this.setActivePane(next);
		next.focus();
	}

	focusPreviousPane(): void {
		if (this.panes.length <= 1) { return; }
		const idx = this._activePane ? this.panes.indexOf(this._activePane) : 0;
		const prev = this.panes[(idx - 1 + this.panes.length) % this.panes.length];
		this.setActivePane(prev);
		prev.focus();
	}

	getPaneCount(): number {
		return this.panes.length;
	}

	getActivePaneIndex(): number {
		if (!this._activePane) { return 0; }
		const idx = this.panes.indexOf(this._activePane);
		return idx >= 0 ? idx : 0;
	}

	focusPaneAtIndex(index: number): void {
		const pane = this.panes[index];
		if (pane) {
			this.setActivePane(pane);
			pane.focus();
		}
	}

	getPanes(): readonly PaneView[] {
		return this.panes;
	}

	//#endregion

	toJSON(): object {
		return {
			type: Parts.PANECONTAINER_PART
		};
	}
}
