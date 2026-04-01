/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../../base/common/event.js';
import { DisposableStore } from '../../../base/common/lifecycle.js';
import { IChannel } from '../../../base/parts/ipc/common/ipc.js';
import { type IAgentSession, type IProject, type IProjectsChangeEvent, IProjectMainService, ProjectStatus } from './projects.js';

export class ProjectMainServiceClient implements IProjectMainService {

	declare readonly _serviceBrand: undefined;

	private readonly disposables = new DisposableStore();

	private readonly _onDidChangeProjects = this.disposables.add(new Emitter<IProjectsChangeEvent>());
	readonly onDidChangeProjects: Event<IProjectsChangeEvent> = this._onDidChangeProjects.event;

	private readonly _onDidChangeActiveProject = this.disposables.add(new Emitter<IProject | undefined>());
	readonly onDidChangeActiveProject: Event<IProject | undefined> = this._onDidChangeActiveProject.event;

	constructor(private readonly channel: IChannel) {
		this.disposables.add(this.channel.listen<IProjectsChangeEvent>('onDidChangeProjects')(e => this._onDidChangeProjects.fire(e)));
		this.disposables.add(this.channel.listen<IProject | undefined>('onDidChangeActiveProject')(e => this._onDidChangeActiveProject.fire(e)));
	}

	getProjects(): Promise<IProject[]> {
		return this.channel.call('getProjects');
	}

	getProject(id: string): Promise<IProject | undefined> {
		return this.channel.call('getProject', id);
	}

	getActiveProject(): Promise<IProject | undefined> {
		return this.channel.call('getActiveProject');
	}

	switchToProject(id: string): Promise<void> {
		return this.channel.call('switchToProject', id);
	}

	createProject(name: string, folderUri?: string): Promise<IProject> {
		return this.channel.call('createProject', [name, folderUri]);
	}

	renameProject(id: string, newName: string): Promise<void> {
		return this.channel.call('renameProject', [id, newName]);
	}

	deleteProject(id: string): Promise<void> {
		return this.channel.call('deleteProject', id);
	}

	updateProjectStatus(id: string, status: ProjectStatus): Promise<void> {
		return this.channel.call('updateProjectStatus', [id, status]);
	}

	updateAgentSessions(id: string, sessions: IAgentSession[]): Promise<void> {
		return this.channel.call('updateAgentSessions', [id, sessions]);
	}

	updateProjectFolder(id: string, folderUri: string): Promise<void> {
		return this.channel.call('updateProjectFolder', [id, folderUri]);
	}

	getProjectForWindow(windowId: number): Promise<IProject | undefined> {
		return this.channel.call('getProjectForWindow', windowId);
	}

	getWindowForProject(projectId: string): Promise<number | undefined> {
		return this.channel.call('getWindowForProject', projectId);
	}

	getProjectByWebContentsId(webContentsId: number): Promise<IProject | undefined> {
		return this.channel.call('getProjectByWebContentsId', webContentsId);
	}

	openFolderInProject(projectId: string, folderUri: string): Promise<void> {
		return this.channel.call('openFolderInProject', [projectId, folderUri]);
	}

	reloadProject(projectId: string): Promise<void> {
		return this.channel.call('reloadProject', projectId);
	}

	openRemoteInProject(projectId: string, remoteAuthority: string): Promise<void> {
		return this.channel.call('openRemoteInProject', [projectId, remoteAuthority]);
	}

	createProjectWithRemote(name: string, remoteAuthority: string): Promise<IProject> {
		return this.channel.call('createProjectWithRemote', [name, remoteAuthority]);
	}

	dispose(): void {
		this.disposables.dispose();
	}
}
