/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import './media/projectBarPart.css';
import { Part } from '../../part.js';
import { Parts, IWorkbenchLayoutService } from '../../../services/layout/browser/layoutService.js';
import { IThemeService } from '../../../../platform/theme/common/themeService.js';
import { IStorageService, StorageScope, StorageTarget } from '../../../../platform/storage/common/storage.js';
import { DisposableStore, MutableDisposable } from '../../../../base/common/lifecycle.js';
import { $, addDisposableListener, append, clearNode, EventType, getWindow } from '../../../../base/browser/dom.js';
import { ACTIVITY_BAR_BACKGROUND, ACTIVITY_BAR_BORDER } from '../../../common/theme.js';
import { contrastBorder } from '../../../../platform/theme/common/colorRegistry.js';
import { assertReturnsDefined } from '../../../../base/common/types.js';
import { ThemeIcon } from '../../../../base/common/themables.js';
import { Codicon } from '../../../../base/common/codicons.js';
import { IHoverService } from '../../../../platform/hover/browser/hover.js';
import { HoverPosition } from '../../../../base/browser/ui/hover/hoverWidget.js';
import { IContextMenuService } from '../../../../platform/contextview/browser/contextView.js';
import { Action, Separator } from '../../../../base/common/actions.js';
import { StandardMouseEvent } from '../../../../base/browser/mouseEvent.js';
import { IQuickInputService } from '../../../../platform/quickinput/common/quickInput.js';
import type { IProject } from '../../../../platform/projects/common/projects.js';
import { IProjectMainService } from '../../../../platform/projects/common/projects.js';
import { IWorkspaceContextService } from '../../../../platform/workspace/common/workspace.js';
import { localize } from '../../../../nls.js';

const HOVER_GROUP_ID = 'projectbar';
const COLLAPSED_WIDTH = 48;
const EXPANDED_WIDTH = 200;
const PROJECTBAR_EXPANDED_KEY = 'dockcode.projectBar.expanded';

export class ProjectBarPart extends Part {

	static readonly ACTION_HEIGHT = 48;

	//#region IView

	private _expanded = false;

	get minimumWidth(): number { return this._expanded ? EXPANDED_WIDTH : COLLAPSED_WIDTH; }
	get maximumWidth(): number { return this._expanded ? EXPANDED_WIDTH : COLLAPSED_WIDTH; }
	readonly minimumHeight: number = 0;
	readonly maximumHeight: number = Number.POSITIVE_INFINITY;

	//#endregion

	private content: HTMLElement | undefined;
	private actionsContainer: HTMLElement | undefined;
	private readonly entryDisposables = this._register(new MutableDisposable<DisposableStore>());
	private _renderVersion = 0;

	constructor(
		@IWorkbenchLayoutService layoutService: IWorkbenchLayoutService,
		@IThemeService themeService: IThemeService,
		@IStorageService private readonly storageService2: IStorageService,
		@IProjectMainService private readonly projectService: IProjectMainService,
		@IHoverService private readonly hoverService: IHoverService,
		@IContextMenuService private readonly contextMenuService: IContextMenuService,
		@IQuickInputService private readonly quickInputService: IQuickInputService,
		@IWorkspaceContextService private readonly contextService: IWorkspaceContextService,
	) {
		super(Parts.PROJECTBAR_PART, { hasTitle: false }, themeService, storageService2, layoutService);
		this._expanded = this.storageService2.getBoolean(PROJECTBAR_EXPANDED_KEY, StorageScope.APPLICATION, false);
	}

	private toggleExpanded(): void {
		this._expanded = !this._expanded;
		this.storageService2.store(PROJECTBAR_EXPANDED_KEY, this._expanded, StorageScope.APPLICATION, StorageTarget.MACHINE);
		this.element?.classList.toggle('expanded', this._expanded);
		this._onDidChange.fire(undefined);
		this.renderContent();
	}

	protected override createContentArea(parent: HTMLElement): HTMLElement {
		this.element = parent;
		if (this._expanded) {
			this.element.classList.add('expanded');
		}
		this.content = append(this.element, $('.content'));
		this.actionsContainer = append(this.content, $('.actions-container'));

		this.renderContent();

		this._register(this.projectService.onDidChangeProjects(() => this.renderContent()));
		this._register(this.projectService.onDidChangeActiveProject(() => this.renderContent()));

		return this.content;
	}

	private renderContent(): void {
		if (!this.actionsContainer) {
			return;
		}

		clearNode(this.actionsContainer);
		this.entryDisposables.value = new DisposableStore();
		this._renderVersion++;

		this.createToggleButton(this.actionsContainer);
		this.createAddButton(this.actionsContainer);
		this.createProjectEntriesAsync(this.actionsContainer, this._renderVersion);
	}

	private createToggleButton(container: HTMLElement): void {
		const disposables = this.entryDisposables.value!;
		const button = append(container, $('.action-item.toggle-expand'));
		const label = append(button, $('span.action-label'));
		const icon = this._expanded ? Codicon.chevronLeft : Codicon.chevronRight;
		label.classList.add(...ThemeIcon.asClassNameArray(icon));

		if (this._expanded) {
			const text = append(button, $('span.action-text'));
			text.textContent = localize('projectbar.collapse', "Collapse");
		}

		disposables.add(
			addDisposableListener(button, EventType.CLICK, () => {
				this.toggleExpanded();
			})
		);

		button.setAttribute('tabindex', '0');
		button.setAttribute('role', 'button');
		button.setAttribute('aria-label', this._expanded
			? localize('projectbar.collapse', "Collapse")
			: localize('projectbar.expand', "Expand"));
	}

	private createAddButton(container: HTMLElement): void {
		const disposables = this.entryDisposables.value!;
		const button = append(container, $('.action-item.add-project'));
		const label = append(button, $('span.action-label'));
		label.classList.add(...ThemeIcon.asClassNameArray(Codicon.add));

		if (this._expanded) {
			const text = append(button, $('span.action-text'));
			text.textContent = localize('projectbar.addProject', "New Project");
		}

		if (!this._expanded) {
			disposables.add(
				this.hoverService.setupDelayedHover(
					button,
					{
						appearance: { showPointer: true },
						position: { hoverPosition: HoverPosition.RIGHT },
						content: localize('projectbar.addProject', "New Project")
					},
					{ groupId: HOVER_GROUP_ID }
				)
			);
		}

		disposables.add(
			addDisposableListener(button, EventType.CLICK, () => {
				this.createNewProject();
			})
		);

		button.setAttribute('tabindex', '0');
		button.setAttribute('role', 'button');
		button.setAttribute('aria-label', localize('projectbar.addProject', "New Project"));
		disposables.add(
			addDisposableListener(button, EventType.KEY_DOWN, (e: KeyboardEvent) => {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					this.createNewProject();
				}
			})
		);
	}

	private async createNewProject(): Promise<void> {
		const name = await this.quickInputService.input({
			placeHolder: localize('projectbar.newProjectPlaceholder', "Project name"),
			title: localize('projectbar.newProjectTitle', "New Project"),
		});
		if (name) {
			const currentFolders = this.contextService.getWorkspace().folders;
			const folderUri = currentFolders.length > 0 ? currentFolders[0].uri.toString() : undefined;
			await this.projectService.createProject(name, folderUri);
		}
	}

	private async createProjectEntriesAsync(container: HTMLElement, version: number): Promise<void> {
		const [projects, activeProject] = await Promise.all([
			this.projectService.getProjects(),
			this.projectService.getActiveProject(),
		]);

		if (version !== this._renderVersion) {
			return; // stale render, discard
		}

		for (const project of projects) {
			this.createProjectEntry(container, project, activeProject?.id === project.id);
		}
	}

	private createProjectEntry(container: HTMLElement, project: IProject, isActive: boolean): void {
		const disposables = this.entryDisposables.value!;

		const entry = append(container, $('.action-item.project-entry'));
		const label = append(entry, $('span.action-label.project-icon'));
		append(entry, $('span.active-item-indicator'));

		label.textContent = project.name.charAt(0).toUpperCase();

		if (this._expanded) {
			const text = append(entry, $('span.action-text'));
			text.textContent = project.name;
		}

		if (isActive) {
			entry.classList.add('checked');
		}

		if (!this._expanded) {
			disposables.add(
				this.hoverService.setupDelayedHover(
					entry,
					{
						appearance: { showPointer: true },
						position: { hoverPosition: HoverPosition.RIGHT },
						content: project.name
					},
					{ groupId: HOVER_GROUP_ID }
				)
			);
		}

		disposables.add(
			addDisposableListener(entry, EventType.CLICK, () => {
				this.projectService.switchToProject(project.id);
			})
		);

		entry.setAttribute('tabindex', '0');
		entry.setAttribute('role', 'button');
		entry.setAttribute('aria-label', project.name);
		entry.setAttribute('aria-pressed', isActive ? 'true' : 'false');
		disposables.add(
			addDisposableListener(entry, EventType.KEY_DOWN, (e: KeyboardEvent) => {
				if (e.key === 'Enter' || e.key === ' ') {
					e.preventDefault();
					this.projectService.switchToProject(project.id);
				}
			})
		);

		disposables.add(
			addDisposableListener(entry, EventType.CONTEXT_MENU, (e: MouseEvent) => {
				e.preventDefault();
				e.stopPropagation();
				const event = new StandardMouseEvent(getWindow(entry), e);
				this.contextMenuService.showContextMenu({
					getAnchor: () => event,
					getActions: () => [
						new Action('projectbar.rename', localize('projectbar.rename', "Rename"), undefined, true, async () => {
							const newName = await this.quickInputService.input({
								placeHolder: localize('projectbar.renamePlaceholder', "New name"),
								title: localize('projectbar.renameTitle', "Rename Project"),
								value: project.name,
							});
							if (newName && newName !== project.name) {
								this.projectService.renameProject(project.id, newName);
							}
						}),
						new Separator(),
						new Action('projectbar.delete', localize('projectbar.delete', "Delete"), undefined, true, () => {
							this.projectService.deleteProject(project.id);
						}),
					]
				});
			})
		);
	}

	override updateStyles(): void {
		super.updateStyles();

		const container = assertReturnsDefined(this.getContainer());
		const background = this.getColor(ACTIVITY_BAR_BACKGROUND) || '';
		container.style.backgroundColor = background;

		const borderColor = this.getColor(ACTIVITY_BAR_BORDER) || this.getColor(contrastBorder) || '';
		container.classList.toggle('bordered', !!borderColor);
		container.style.borderColor = borderColor ? borderColor : '';
	}

	focus(): void {
		this.actionsContainer?.querySelector<HTMLElement>('.action-item')?.focus();
	}

	override layout(width: number, height: number): void {
		super.layout(width, height, 0, 0);
	}

	toJSON(): object {
		return {
			type: Parts.PROJECTBAR_PART
		};
	}
}
