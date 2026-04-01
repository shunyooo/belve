/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

/* eslint-disable @typescript-eslint/no-explicit-any */

import { Event } from '../../../base/common/event.js';
import { IServerChannel } from '../../../base/parts/ipc/common/ipc.js';
import { IProjectMainService } from '../common/projects.js';

export class ProjectMainServiceChannel implements IServerChannel {

	constructor(private readonly service: IProjectMainService) { }

	listen(_: unknown, event: string): Event<any> {
		switch (event) {
			case 'onDidChangeProjects': return this.service.onDidChangeProjects;
			case 'onDidChangeActiveProject': return this.service.onDidChangeActiveProject;
		}

		throw new Error(`Event not found: ${event}`);
	}

	call(_: unknown, command: string, arg?: any): Promise<any> {
		switch (command) {
			case 'getProjects': return this.service.getProjects();
			case 'getProject': return this.service.getProject(arg);
			case 'getActiveProject': return this.service.getActiveProject();
			case 'switchToProject': return this.service.switchToProject(arg);
			case 'createProject': return this.service.createProject(arg[0], arg[1]);
			case 'renameProject': return this.service.renameProject(arg[0], arg[1]);
			case 'deleteProject': return this.service.deleteProject(arg);
			case 'updateProjectStatus': return this.service.updateProjectStatus(arg[0], arg[1]);
			case 'updateAgentSessions': return this.service.updateAgentSessions(arg[0], arg[1]);
			case 'updateProjectFolder': return this.service.updateProjectFolder(arg[0], arg[1]);
			case 'getProjectForWindow': return this.service.getProjectForWindow(arg);
			case 'getWindowForProject': return this.service.getWindowForProject(arg);
			case 'getProjectByWebContentsId': return this.service.getProjectByWebContentsId(arg);
			case 'openFolderInProject': return this.service.openFolderInProject(arg[0], arg[1]);
			case 'reloadProject': return this.service.reloadProject(arg);
			case 'openRemoteInProject': return this.service.openRemoteInProject(arg[0], arg[1]);
			case 'createProjectWithRemote': return this.service.createProjectWithRemote(arg[0], arg[1]);
		}

		throw new Error(`Call not found: ${command}`);
	}
}
