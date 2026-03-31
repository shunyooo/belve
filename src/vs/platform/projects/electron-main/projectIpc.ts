/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

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
			case 'updateProjectFolder': return this.service.updateProjectFolder(arg[0], arg[1]);
			case 'getProjectForWindow': return this.service.getProjectForWindow(arg);
			case 'getWindowForProject': return this.service.getWindowForProject(arg);
		}

		throw new Error(`Call not found: ${command}`);
	}
}
