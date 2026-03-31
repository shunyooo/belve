/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { URI } from '../../../../base/common/uri.js';
import { Disposable } from '../../../../base/common/lifecycle.js';
import { IWorkbenchContribution } from '../../../common/contributions.js';
import { IProjectService } from '../common/project.js';
import { IEditorGroupsService } from '../../../services/editor/common/editorGroupsService.js';
import { ITerminalService } from '../../terminal/browser/terminal.js';
import { IStorageService, StorageScope, StorageTarget } from '../../../../platform/storage/common/storage.js';
import { IWorkspaceContextService } from '../../../../platform/workspace/common/workspace.js';
import { IHostService } from '../../../services/host/browser/host.js';

const TERMINAL_OWNERSHIP_KEY = 'dockcode.projectTerminals';

interface ITerminalOwnershipData {
	[terminalId: number]: string; // terminalId -> projectId
}

export class ProjectStateSwitcher extends Disposable implements IWorkbenchContribution {

	static readonly ID = 'workbench.contrib.projectStateSwitcher';

	private readonly terminalOwnership = new Map<number, string>();
	private switching = false;

	constructor(
		@IProjectService private readonly projectService: IProjectService,
		@IEditorGroupsService private readonly editorGroupsService: IEditorGroupsService,
		@ITerminalService private readonly terminalService: ITerminalService,
		@IStorageService private readonly storageService: IStorageService,
		@IWorkspaceContextService private readonly contextService: IWorkspaceContextService,
		@IHostService private readonly hostService: IHostService,
	) {
		super();

		this.loadTerminalOwnership();

		// Save outgoing project state before switch
		this._register(this.projectService.onWillChangeActiveProject(e => {
			if (this.switching) {
				return;
			}
			this.switching = true;

			if (e.from) {
				this.saveProjectState(e.from.id);
			}
		}));

		// Restore incoming project state after switch
		this._register(this.projectService.onDidChangeActiveProject(async project => {
			try {
				if (project) {
					await this.restoreProjectState(project.id);
				} else {
					// No active project — show empty
					this.editorGroupsService.applyWorkingSet('empty');
					this.hideAllTerminals();
				}
			} finally {
				this.switching = false;
			}
		}));

		// Track new terminals to the active project
		this._register(this.terminalService.onDidCreateInstance(instance => {
			const active = this.projectService.getActiveProject();
			if (active) {
				this.terminalOwnership.set(instance.instanceId, active.id);
				this.saveTerminalOwnership();
			}
		}));
	}

	private saveProjectState(projectId: string): void {
		// Save current workspace folder to the project
		const currentFolders = this.contextService.getWorkspace().folders;
		if (currentFolders.length > 0) {
			this.projectService.updateProjectFolder(projectId, currentFolders[0].uri.toString());
		}

		// Save editor working set
		const name = `__project__${projectId}`;

		// Delete old working set if exists
		const existing = this.editorGroupsService.getWorkingSets().find(ws => ws.name === name);
		if (existing) {
			this.editorGroupsService.deleteWorkingSet(existing);
		}

		this.editorGroupsService.saveWorkingSet(name);

		// Move project's terminals to background
		for (const instance of this.terminalService.instances) {
			if (this.terminalOwnership.get(instance.instanceId) === projectId) {
				this.terminalService.moveToBackground(instance);
			}
		}
	}

	private async restoreProjectState(projectId: string): Promise<void> {
		// Switch workspace folder via openWindow (reuses the same window)
		const project = this.projectService.getProject(projectId);
		if (project?.folderUri) {
			const targetUri = URI.parse(project.folderUri);
			const currentFolders = this.contextService.getWorkspace().folders;
			const alreadyOpen = currentFolders.length === 1 && currentFolders[0].uri.toString() === project.folderUri;
			if (!alreadyOpen) {
				// This reloads the window with the new folder
				await this.hostService.openWindow([{ folderUri: targetUri }], { forceReuseWindow: true });
				return; // window will reload, no need to restore editors/terminals
			}
		}

		// Restore editor working set
		const name = `__project__${projectId}`;
		const workingSet = this.editorGroupsService.getWorkingSets().find(ws => ws.name === name);

		if (workingSet) {
			this.editorGroupsService.applyWorkingSet(workingSet);
		} else {
			this.editorGroupsService.applyWorkingSet('empty');
		}

		// Hide all terminals first, then show this project's
		this.hideAllTerminals();

		for (const [terminalId, ownerProjectId] of this.terminalOwnership) {
			if (ownerProjectId === projectId) {
				const instance = this.terminalService.getInstanceFromId(terminalId);
				if (instance) {
					this.terminalService.showBackgroundTerminal(instance, true);
				}
			}
		}
	}

	private hideAllTerminals(): void {
		for (const instance of [...this.terminalService.instances]) {
			this.terminalService.moveToBackground(instance);
		}
	}

	private loadTerminalOwnership(): void {
		const raw = this.storageService.get(TERMINAL_OWNERSHIP_KEY, StorageScope.APPLICATION);
		if (raw) {
			try {
				const data: ITerminalOwnershipData = JSON.parse(raw);
				for (const [id, projectId] of Object.entries(data)) {
					this.terminalOwnership.set(Number(id), projectId);
				}
			} catch {
				// ignore
			}
		}
	}

	private saveTerminalOwnership(): void {
		const data: ITerminalOwnershipData = {};
		for (const [id, projectId] of this.terminalOwnership) {
			data[id] = projectId;
		}
		this.storageService.store(TERMINAL_OWNERSHIP_KEY, JSON.stringify(data), StorageScope.APPLICATION, StorageTarget.MACHINE);
	}
}
