/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { Emitter, Event } from '../../../../base/common/event.js';
import { Disposable } from '../../../../base/common/lifecycle.js';
import { generateUuid } from '../../../../base/common/uuid.js';
import { IContextKeyService } from '../../../../platform/contextkey/common/contextkey.js';
import { IStorageService, StorageScope, StorageTarget } from '../../../../platform/storage/common/storage.js';
import { ActiveProjectContext, IProject, IProjectData, IProjectService, IProjectsChangeEvent, ProjectCountContext, ProjectStatus } from '../common/project.js';

const PROJECTS_STORAGE_KEY = 'dockcode.projects';
const ACTIVE_PROJECT_STORAGE_KEY = 'dockcode.activeProjectId';

export class ProjectService extends Disposable implements IProjectService {
	declare readonly _serviceBrand: undefined;

	private projects: IProject[] = [];
	private activeProjectId: string | undefined;

	private readonly _onDidChangeProjects = this._register(new Emitter<IProjectsChangeEvent>());
	readonly onDidChangeProjects: Event<IProjectsChangeEvent> = this._onDidChangeProjects.event;

	private readonly _onDidChangeActiveProject = this._register(new Emitter<IProject | undefined>());
	readonly onDidChangeActiveProject: Event<IProject | undefined> = this._onDidChangeActiveProject.event;

	private readonly activeProjectContext;
	private readonly projectCountContext;

	constructor(
		@IStorageService private readonly storageService: IStorageService,
		@IContextKeyService contextKeyService: IContextKeyService,
	) {
		super();
		this.activeProjectContext = ActiveProjectContext.bindTo(contextKeyService);
		this.projectCountContext = ProjectCountContext.bindTo(contextKeyService);
		this.loadFromStorage();
	}

	private loadFromStorage(): void {
		const raw = this.storageService.get(PROJECTS_STORAGE_KEY, StorageScope.WORKSPACE);
		if (raw) {
			try {
				const data: IProjectData[] = JSON.parse(raw);
				this.projects = data.map(d => ({ ...d }));
			} catch {
				this.projects = [];
			}
		}
		this.activeProjectId = this.storageService.get(ACTIVE_PROJECT_STORAGE_KEY, StorageScope.WORKSPACE);
		this.updateContextKeys();
	}

	private saveToStorage(): void {
		const data: IProjectData[] = this.projects.map(p => ({
			id: p.id,
			name: p.name,
			createdAt: p.createdAt,
			status: p.status,
		}));
		this.storageService.store(PROJECTS_STORAGE_KEY, JSON.stringify(data), StorageScope.WORKSPACE, StorageTarget.MACHINE);
		if (this.activeProjectId) {
			this.storageService.store(ACTIVE_PROJECT_STORAGE_KEY, this.activeProjectId, StorageScope.WORKSPACE, StorageTarget.MACHINE);
		} else {
			this.storageService.remove(ACTIVE_PROJECT_STORAGE_KEY, StorageScope.WORKSPACE);
		}
	}

	private updateContextKeys(): void {
		this.activeProjectContext.set(this.activeProjectId ?? '');
		this.projectCountContext.set(this.projects.length);
	}

	getProjects(): IProject[] {
		return [...this.projects];
	}

	getProject(id: string): IProject | undefined {
		return this.projects.find(p => p.id === id);
	}

	getActiveProject(): IProject | undefined {
		if (!this.activeProjectId) {
			return undefined;
		}
		return this.projects.find(p => p.id === this.activeProjectId);
	}

	setActiveProject(id: string): void {
		if (this.activeProjectId === id) {
			return;
		}
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		this.activeProjectId = id;
		this.saveToStorage();
		this.updateContextKeys();
		this._onDidChangeActiveProject.fire(project);
	}

	createProject(name: string): IProject {
		const project: IProject = {
			id: generateUuid(),
			name,
			createdAt: Date.now(),
			status: ProjectStatus.Idle,
		};
		this.projects.push(project);
		this.saveToStorage();
		this.updateContextKeys();
		this._onDidChangeProjects.fire({ added: [project], removed: [], changed: [] });
		return project;
	}

	renameProject(id: string, newName: string): void {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		(project as { name: string }).name = newName;
		this.saveToStorage();
		this._onDidChangeProjects.fire({ added: [], removed: [], changed: [project] });
	}

	deleteProject(id: string): void {
		const index = this.projects.findIndex(p => p.id === id);
		if (index === -1) {
			return;
		}
		const [removed] = this.projects.splice(index, 1);
		if (this.activeProjectId === id) {
			this.activeProjectId = this.projects[0]?.id;
			this._onDidChangeActiveProject.fire(this.getActiveProject());
		}
		this.saveToStorage();
		this.updateContextKeys();
		this._onDidChangeProjects.fire({ added: [], removed: [removed], changed: [] });
	}

	updateProjectStatus(id: string, status: ProjectStatus): void {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		project.status = status;
		this.saveToStorage();
		this._onDidChangeProjects.fire({ added: [], removed: [], changed: [project] });
	}
}
