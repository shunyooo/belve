/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import './media/projectsView.css';
import * as DOM from '../../../../../base/browser/dom.js';
import { IConfigurationService } from '../../../../../platform/configuration/common/configuration.js';
import { IContextKeyService } from '../../../../../platform/contextkey/common/contextkey.js';
import { IContextMenuService } from '../../../../../platform/contextview/browser/contextView.js';
import { IHoverService } from '../../../../../platform/hover/browser/hover.js';
import { IInstantiationService } from '../../../../../platform/instantiation/common/instantiation.js';
import { IKeybindingService } from '../../../../../platform/keybinding/common/keybinding.js';
import { IOpenerService } from '../../../../../platform/opener/common/opener.js';

import { IThemeService } from '../../../../../platform/theme/common/themeService.js';
import { IViewPaneOptions, ViewPane } from '../../../../browser/parts/views/viewPane.js';
import { IViewDescriptorService } from '../../../../common/views.js';
import type { IProject } from '../../../../../platform/projects/common/projects.js';
import { IProjectMainService, ProjectStatus } from '../../../../../platform/projects/common/projects.js';
import { IDialogService } from '../../../../../platform/dialogs/common/dialogs.js';
import { localize } from '../../../../../nls.js';

const $ = DOM.$;

export class ProjectsView extends ViewPane {

	private listContainer: HTMLElement | undefined;
	private summaryContainer: HTMLElement | undefined;
	private _renderVersion = 0;

	constructor(
		options: IViewPaneOptions,
		@IKeybindingService keybindingService: IKeybindingService,
		@IContextMenuService contextMenuService: IContextMenuService,
		@IConfigurationService configurationService: IConfigurationService,
		@IContextKeyService contextKeyService: IContextKeyService,
		@IViewDescriptorService viewDescriptorService: IViewDescriptorService,
		@IInstantiationService instantiationService: IInstantiationService,
		@IOpenerService openerService: IOpenerService,
		@IThemeService themeService: IThemeService,
		@IHoverService hoverService: IHoverService,
		@IProjectMainService private readonly projectService: IProjectMainService,
		@IDialogService private readonly dialogService: IDialogService,
	) {
		super(options, keybindingService, contextMenuService, configurationService, contextKeyService, viewDescriptorService, instantiationService, openerService, themeService, hoverService);
	}

	protected override renderBody(parent: HTMLElement): void {
		super.renderBody(parent);
		parent.classList.add('projects-view');

		this.listContainer = DOM.append(parent, $('.projects-list'));
		this.summaryContainer = DOM.append(parent, $('.projects-status-summary'));

		this.renderProjectList();

		this._register(this.projectService.onDidChangeProjects(() => this.renderProjectList()));
		this._register(this.projectService.onDidChangeActiveProject(() => this.renderProjectList()));
	}

	private async renderProjectList(): Promise<void> {
		if (!this.listContainer || !this.summaryContainer) {
			return;
		}

		DOM.clearNode(this.listContainer);
		const version = ++this._renderVersion;

		const [projects, activeProject] = await Promise.all([
			this.projectService.getProjects(),
			this.projectService.getActiveProject(),
		]);

		if (version !== this._renderVersion) {
			return; // stale render, discard
		}

		for (const project of projects) {
			const isActive = activeProject?.id === project.id;
			const item = DOM.append(this.listContainer, $('.project-item'));
			if (isActive) {
				item.classList.add('active');
			}

			const statusDot = DOM.append(item, $('.project-status'));
			statusDot.classList.add(`status-${project.status}`);

			const nameEl = DOM.append(item, $('.project-name'));
			nameEl.textContent = project.name;

			this._register(DOM.addDisposableListener(item, DOM.EventType.CLICK, () => {
				this.projectService.switchToProject(project.id);
			}));

			this._register(DOM.addDisposableListener(item, DOM.EventType.CONTEXT_MENU, (e: MouseEvent) => {
				e.preventDefault();
				this.showProjectContextMenu(project, nameEl);
			}));
		}

		this.renderStatusSummary(projects);
	}

	private async startInlineRename(projectId: string, nameEl: HTMLElement): Promise<void> {
		const project = await this.projectService.getProject(projectId);
		if (!project) {
			return;
		}

		const input = DOM.$('input.project-name-input') as HTMLInputElement;
		input.type = 'text';
		input.value = project.name;
		nameEl.replaceWith(input);
		input.focus();
		input.select();

		let committed = false;
		const commit = () => {
			if (committed) {
				return;
			}
			committed = true;
			const newName = input.value.trim();
			if (newName && newName !== project.name) {
				this.projectService.renameProject(projectId, newName);
			} else {
				this.renderProjectList();
			}
		};

		this._register(DOM.addDisposableListener(input, DOM.EventType.KEY_DOWN, (e: KeyboardEvent) => {
			if (e.key === 'Enter') {
				e.preventDefault();
				commit();
			} else if (e.key === 'Escape') {
				e.preventDefault();
				committed = true;
				this.renderProjectList();
			}
		}));

		this._register(DOM.addDisposableListener(input, DOM.EventType.BLUR, () => {
			commit();
		}));
	}

	private renderStatusSummary(projects: IProject[]): void {
		if (!this.summaryContainer) {
			return;
		}

		const running = projects.filter(p => p.status === ProjectStatus.Running).length;
		const idle = projects.filter(p => p.status === ProjectStatus.Idle).length;
		const error = projects.filter(p => p.status === ProjectStatus.Error).length;

		const parts: string[] = [];
		if (running > 0) {
			parts.push(`${running} running`);
		}
		if (idle > 0) {
			parts.push(`${idle} idle`);
		}
		if (error > 0) {
			parts.push(`${error} error`);
		}

		this.summaryContainer.textContent = parts.length > 0 ? parts.join(', ') : 'No projects';
	}

	private showProjectContextMenu(project: IProject, anchor: HTMLElement): void {
		this.contextMenuService.showContextMenu({
			getAnchor: () => anchor,
			getActions: () => [
				{
					id: 'dockcode.projects.rename',
					label: localize('renameProject', "Rename"),
					enabled: true,
					class: undefined,
					tooltip: '',
					run: () => {
						this.startInlineRename(project.id, anchor);
					},
				},
				{
					id: 'dockcode.projects.delete',
					label: localize('deleteProject', "Delete"),
					enabled: true,
					class: undefined,
					tooltip: '',
					run: async () => {
						const confirmed = await this.dialogService.confirm({
							message: localize('deleteProjectConfirm', "Delete project \"{0}\"?", project.name),
						});
						if (confirmed.confirmed) {
							this.projectService.deleteProject(project.id);
						}
					},
				},
			],
		});
	}

	protected override layoutBody(height: number, width: number): void {
		super.layoutBody(height, width);
	}
}
