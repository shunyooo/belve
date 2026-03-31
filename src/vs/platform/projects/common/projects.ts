/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Event } from '../../../base/common/event.js';
import { createDecorator } from '../../instantiation/common/instantiation.js';

export enum ProjectStatus {
	Idle = 'idle',
	Running = 'running',
	Error = 'error'
}

export interface IProjectData {
	readonly id: string;
	readonly name: string;
	readonly createdAt: number;
	readonly folderUri?: string;
	status: ProjectStatus;
}

export interface IProject extends IProjectData { }

export interface IProjectsChangeEvent {
	readonly added: readonly IProject[];
	readonly removed: readonly IProject[];
	readonly changed: readonly IProject[];
}

export const IProjectMainService = createDecorator<IProjectMainService>('dockcode.projectMainService');

export interface IProjectMainService {
	readonly _serviceBrand: undefined;

	readonly onDidChangeProjects: Event<IProjectsChangeEvent>;
	readonly onDidChangeActiveProject: Event<IProject | undefined>;

	getProjects(): Promise<IProject[]>;
	getProject(id: string): Promise<IProject | undefined>;
	getActiveProject(): Promise<IProject | undefined>;

	switchToProject(id: string): Promise<void>;

	createProject(name: string, folderUri?: string): Promise<IProject>;
	renameProject(id: string, newName: string): Promise<void>;
	deleteProject(id: string): Promise<void>;
	updateProjectStatus(id: string, status: ProjectStatus): Promise<void>;
	updateProjectFolder(id: string, folderUri: string): Promise<void>;

	getProjectForWindow(windowId: number): Promise<IProject | undefined>;
	getWindowForProject(projectId: string): Promise<number | undefined>;
}
