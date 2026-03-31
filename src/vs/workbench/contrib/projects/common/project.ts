/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Event } from '../../../../base/common/event.js';
import { RawContextKey } from '../../../../platform/contextkey/common/contextkey.js';
import { createDecorator } from '../../../../platform/instantiation/common/instantiation.js';
import type { IProject, IProjectsChangeEvent } from '../../../../platform/projects/common/projects.js';
import { ProjectStatus } from '../../../../platform/projects/common/projects.js';

// Re-export shared types from platform layer
export type { IProject, IProjectData, IProjectsChangeEvent } from '../../../../platform/projects/common/projects.js';
export { IProjectMainService, ProjectStatus } from '../../../../platform/projects/common/projects.js';

// TODO: Remove IProjectSwitchEvent and IProjectService once migration to IProjectMainService is complete

export interface IProjectSwitchEvent {
	readonly from: IProject | undefined;
	readonly to: IProject;
}

// Renderer-only constants
export const PROJECTS_VIEW_CONTAINER_ID = 'dockcode.workbench.view.projectsContainer';
export const PROJECTS_VIEW_ID = 'dockcode.workbench.view.projectsList';

export const ActiveProjectContext = new RawContextKey<string>('dockcode.activeProjectId', '');
export const ProjectCountContext = new RawContextKey<number>('dockcode.projectCount', 0);

// Legacy renderer-only service interface — will be replaced by IProjectMainService
export const IProjectService = createDecorator<IProjectService>('dockcode.projectService');

export interface IProjectService {
	readonly _serviceBrand: undefined;

	readonly onDidChangeProjects: Event<IProjectsChangeEvent>;
	readonly onWillChangeActiveProject: Event<IProjectSwitchEvent>;
	readonly onDidChangeActiveProject: Event<IProject | undefined>;

	getProjects(): IProject[];
	getProject(id: string): IProject | undefined;
	getActiveProject(): IProject | undefined;
	setActiveProject(id: string): void;
	createProject(name: string, folderUri?: string): IProject;
	renameProject(id: string, newName: string): void;
	deleteProject(id: string): void;
	updateProjectStatus(id: string, status: ProjectStatus): void;
	updateProjectFolder(id: string, folderUri: string): void;
}
