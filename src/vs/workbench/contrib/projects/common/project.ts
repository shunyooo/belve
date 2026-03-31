/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Event } from '../../../../base/common/event.js';
import { RawContextKey } from '../../../../platform/contextkey/common/contextkey.js';
import { createDecorator } from '../../../../platform/instantiation/common/instantiation.js';

export const enum ProjectStatus {
	Idle = 'idle',
	Running = 'running',
	Error = 'error'
}

export interface IProjectData {
	readonly id: string;
	readonly name: string;
	readonly createdAt: number;
	status: ProjectStatus;
}

export interface IProject extends IProjectData { }

export interface IProjectsChangeEvent {
	readonly added: readonly IProject[];
	readonly removed: readonly IProject[];
	readonly changed: readonly IProject[];
}

export const PROJECTS_VIEW_CONTAINER_ID = 'dockcode.workbench.view.projectsContainer';
export const PROJECTS_VIEW_ID = 'dockcode.workbench.view.projectsList';

export const ActiveProjectContext = new RawContextKey<string>('dockcode.activeProjectId', '');
export const ProjectCountContext = new RawContextKey<number>('dockcode.projectCount', 0);

export const IProjectService = createDecorator<IProjectService>('dockcode.projectService');

export interface IProjectService {
	readonly _serviceBrand: undefined;

	readonly onDidChangeProjects: Event<IProjectsChangeEvent>;
	readonly onDidChangeActiveProject: Event<IProject | undefined>;

	getProjects(): IProject[];
	getProject(id: string): IProject | undefined;
	getActiveProject(): IProject | undefined;
	setActiveProject(id: string): void;
	createProject(name: string): IProject;
	renameProject(id: string, newName: string): void;
	deleteProject(id: string): void;
	updateProjectStatus(id: string, status: ProjectStatus): void;
}
