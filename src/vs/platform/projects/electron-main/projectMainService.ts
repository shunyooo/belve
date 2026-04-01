/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { WebContentsView } from 'electron';
import { Emitter, Event } from '../../../base/common/event.js';
import { Disposable, DisposableStore } from '../../../base/common/lifecycle.js';
import { FileAccess, Schemas } from '../../../base/common/network.js';
import { generateUuid } from '../../../base/common/uuid.js';
import { IEnvironmentMainService } from '../../environment/electron-main/environmentMainService.js';
import { ILogService } from '../../log/common/log.js';
import { IWindowsMainService, OpenContext } from '../../windows/electron-main/windows.js';
import { type IAgentSession, type IProject, type IProjectData, type IProjectsChangeEvent, IProjectMainService, ProjectStatus } from '../common/projects.js';
import { IProtocolMainService } from '../../protocol/electron-main/protocol.js';
import { INativeWindowConfiguration } from '../../window/common/window.js';
import { IUserDataProfilesMainService } from '../../userDataProfile/electron-main/userDataProfile.js';
import { ILoggerMainService } from '../../log/electron-main/loggerService.js';
import { getNLSLanguage, getNLSMessages } from '../../../nls.js';
import product from '../../product/common/product.js';
import { hostname, release, arch } from 'os';
import { getMarks } from '../../../base/common/performance.js';
import { IPolicyService } from '../../policy/common/policy.js';
import { ICSSDevelopmentService } from '../../cssDev/node/cssDevService.js';
import { URI } from '../../../base/common/uri.js';
import { getSingleFolderWorkspaceIdentifier } from '../../workspaces/node/workspaces.js';
import * as fs from 'fs';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import type { ISingleFolderWorkspaceIdentifier } from '../../workspace/common/workspace.js';

interface IProjectView {
	readonly view: WebContentsView;
	readonly disposables: DisposableStore;
	readonly configUrl: { update(config: INativeWindowConfiguration): void; dispose(): void };
}

export class ProjectMainService extends Disposable implements IProjectMainService {

	declare readonly _serviceBrand: undefined;

	private projects: IProject[] = [];
	private activeProjectId: string | undefined;

	// For the first project: tracks the main window's webContents id
	private mainWindowProjectId: string | undefined;

	// For additional projects: WebContentsView per project
	private readonly projectViews = new Map<string, IProjectView>();

	/**
	 * Returns all WebContentsView webContents managed by this service.
	 * Used by the security filter to allow vscode-file:// requests.
	 */
	getProjectWebContents(): Electron.WebContents[] {
		const result: Electron.WebContents[] = [];
		for (const [, pv] of this.projectViews) {
			result.push(pv.view.webContents);
		}
		return result;
	}

	private readonly _onDidChangeProjects = this._register(new Emitter<IProjectsChangeEvent>());
	readonly onDidChangeProjects: Event<IProjectsChangeEvent> = this._onDidChangeProjects.event;

	private readonly _onDidChangeActiveProject = this._register(new Emitter<IProject | undefined>());
	readonly onDidChangeActiveProject: Event<IProject | undefined> = this._onDidChangeActiveProject.event;

	private readonly dataFilePath: string;

	constructor(
		@IWindowsMainService private readonly windowsMainService: IWindowsMainService,
		@IEnvironmentMainService private readonly environmentMainService: IEnvironmentMainService,
		@ILogService private readonly logService: ILogService,
		@IProtocolMainService private readonly protocolMainService: IProtocolMainService,
		@IUserDataProfilesMainService private readonly userDataProfilesMainService: IUserDataProfilesMainService,
		@ILoggerMainService private readonly loggerService: ILoggerMainService,
		@IPolicyService private readonly policyService: IPolicyService,
		@ICSSDevelopmentService private readonly cssDevelopmentService: ICSSDevelopmentService,
	) {
		super();

		this.dataFilePath = path.join(this.environmentMainService.userDataPath, 'projects.json');
		this.loadFromDisk();

		// Set up agent event monitoring and hooks
		import('./agentHooksSetup.js').then(({ ensureAgentHooks }) => ensureAgentHooks(this.logService));
		import('./agentEventMonitor.js').then(({ AgentEventMonitor }) => {
			this._register(new AgentEventMonitor(this, this.logService));
		});
	}

	private loadFromDisk(): void {
		console.log(`[ProjectMainService] loadFromDisk: ${this.dataFilePath}`);
		try {
			if (fs.existsSync(this.dataFilePath)) {
				const raw = fs.readFileSync(this.dataFilePath, 'utf-8');
				const data = JSON.parse(raw) as { projects: IProjectData[]; activeProjectId?: string };
				this.projects = data.projects.map(d => ({ ...d }));
				this.activeProjectId = data.activeProjectId;
				console.log(`[ProjectMainService] Loaded ${this.projects.length} project(s) from disk`);
			} else {
				console.log(`[ProjectMainService] No projects.json found at ${this.dataFilePath}`);
			}
		} catch (e) {
			this.logService.error('[ProjectMainService] Failed to load projects:', e);
			this.projects = [];
		}
	}

	private saveToDisk(): void {
		try {
			const data = {
				projects: this.projects.map(p => ({
					id: p.id,
					name: p.name,
					createdAt: p.createdAt,
					folderUri: p.folderUri,
					status: p.status,
				})),
				activeProjectId: this.activeProjectId,
			};
			fs.writeFileSync(this.dataFilePath, JSON.stringify(data, null, '\t'), 'utf-8');
		} catch (e) {
			this.logService.error('[ProjectMainService] Failed to save projects:', e);
		}
	}

	async getProjects(): Promise<IProject[]> {
		return [...this.projects];
	}

	async getProject(id: string): Promise<IProject | undefined> {
		return this.projects.find(p => p.id === id);
	}

	async getActiveProject(): Promise<IProject | undefined> {
		if (!this.activeProjectId) {
			return undefined;
		}
		return this.projects.find(p => p.id === this.activeProjectId);
	}

	async switchToProject(id: string): Promise<void> {
		const project = this.projects.find(p => p.id === id);
		if (!project || this.activeProjectId === id) {
			return;
		}

		const mainWindow = this.windowsMainService.getLastActiveWindow() ?? this.windowsMainService.getWindows()[0];
		if (!mainWindow?.win) {
			return;
		}

		// Hide the current project's view
		if (this.activeProjectId) {
			if (this.activeProjectId === this.mainWindowProjectId) {
				// The main window's webContents is the first project — hide it by hiding the default view
				// We can't hide the main webContents directly, but we can cover it with the new view
			} else {
				const currentView = this.projectViews.get(this.activeProjectId);
				if (currentView) {
					currentView.view.setVisible(false);
				}
			}
		}

		this.activeProjectId = id;

		// Show the target project's view
		if (id === this.mainWindowProjectId) {
			// Switching back to the main window project — hide all WebContentsViews
			for (const [, pv] of this.projectViews) {
				pv.view.setVisible(false);
			}
			// Focus the main window's webContents
			mainWindow.win.webContents.focus();
		} else {
			const targetView = this.projectViews.get(id);
			if (targetView) {
				targetView.view.setVisible(true);
				targetView.view.webContents.focus();
			}
		}

		this.saveToDisk();
		this._onDidChangeActiveProject.fire(project);
	}

	async createProject(name: string, folderUri?: string): Promise<IProject> {
		const project: IProject = {
			id: generateUuid(),
			name,
			createdAt: Date.now(),
			folderUri,
			status: ProjectStatus.Idle,
		};
		this.projects.push(project);

		const mainWindow = this.windowsMainService.getFocusedWindow()
			?? this.windowsMainService.getLastActiveWindow();

		if (!this.mainWindowProjectId && mainWindow) {
			// First project: adopt the main window's webContents
			this.mainWindowProjectId = project.id;
			this.logService.info(`[ProjectMainService] First project "${name}" adopted main window`);
		} else if (mainWindow?.win) {
			// Additional project: create a WebContentsView
			await this.createViewForProject(project, mainWindow.win);

			// Hide other views, show the new one
			if (this.activeProjectId && this.activeProjectId !== this.mainWindowProjectId) {
				const currentView = this.projectViews.get(this.activeProjectId);
				if (currentView) {
					currentView.view.setVisible(false);
				}
			}
		}

		this.activeProjectId = project.id;
		this.saveToDisk();
		this._onDidChangeProjects.fire({ added: [project], removed: [], changed: [] });
		this._onDidChangeActiveProject.fire(project);
		return project;
	}

	async renameProject(id: string, newName: string): Promise<void> {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		(project as { name: string }).name = newName;
		this.saveToDisk();
		this._onDidChangeProjects.fire({ added: [], removed: [], changed: [project] });
	}

	async deleteProject(id: string): Promise<void> {
		const index = this.projects.findIndex(p => p.id === id);
		if (index === -1) {
			return;
		}
		const [removed] = this.projects.splice(index, 1);

		// Dispose the project's view
		const view = this.projectViews.get(id);
		if (view) {
			const mainWindow = this.windowsMainService.getWindows()[0];
			if (mainWindow?.win) {
				mainWindow.win.contentView.removeChildView(view.view);
			}
			view.configUrl.dispose();
			view.disposables.dispose();
			this.projectViews.delete(id);
		}

		if (id === this.mainWindowProjectId) {
			this.mainWindowProjectId = undefined;
		}

		// Switch to next project if we deleted the active one
		if (this.activeProjectId === id) {
			const nextProject = this.projects[0];
			this.activeProjectId = nextProject?.id;
			if (nextProject) {
				await this.switchToProject(nextProject.id);
			}
			this._onDidChangeActiveProject.fire(nextProject);
		}

		this.saveToDisk();
		this._onDidChangeProjects.fire({ added: [], removed: [removed], changed: [] });
	}

	async updateProjectStatus(id: string, status: ProjectStatus): Promise<void> {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		project.status = status;
		this.saveToDisk();
		this._onDidChangeProjects.fire({ added: [], removed: [], changed: [project] });
	}

	async updateAgentSessions(id: string, sessions: IAgentSession[]): Promise<void> {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		(project as { agentSessions?: IAgentSession[] }).agentSessions = sessions;
		this._onDidChangeProjects.fire({ added: [], removed: [], changed: [project] });
	}

	async updateProjectFolder(id: string, folderUri: string): Promise<void> {
		const project = this.projects.find(p => p.id === id);
		if (!project) {
			return;
		}
		(project as { folderUri?: string }).folderUri = folderUri;
		this.saveToDisk();
	}

	async getProjectForWindow(windowId: number): Promise<IProject | undefined> {
		// In WebContentsView mode, all projects share the same window
		return this.projects.find(p => p.id === this.activeProjectId);
	}

	async getWindowForProject(projectId: string): Promise<number | undefined> {
		const mainWindow = this.windowsMainService.getWindows()[0];
		return mainWindow?.id;
	}

	/**
	 * Synchronously resolves a WebContentsView's webContents and parent BrowserWindow
	 * for a given webContentsId. Used by UtilityProcess to route IPC to the correct renderer.
	 */
	getProjectViewInfo(webContentsId: number): { webContents: Electron.WebContents; parentWindow: Electron.BrowserWindow } | undefined {
		for (const [, pv] of this.projectViews) {
			if (pv.view.webContents.id === webContentsId) {
				const mainWindow = this.windowsMainService.getWindows()[0];
				if (mainWindow?.win) {
					return { webContents: pv.view.webContents, parentWindow: mainWindow.win };
				}
			}
		}
		return undefined;
	}

	async getProjectByWebContentsId(webContentsId: number): Promise<IProject | undefined> {
		console.log(`[ProjectMainService] getProjectByWebContentsId(${webContentsId}), projectViews has ${this.projectViews.size} entries: [${[...this.projectViews.entries()].map(([id, pv]) => `${id.substring(0, 8)}:wc=${pv.view.webContents.id}`).join(', ')}]`);
		for (const [projectId, pv] of this.projectViews) {
			if (pv.view.webContents.id === webContentsId) {
				return this.projects.find(p => p.id === projectId);
			}
		}
		return undefined;
	}

	async openFolderInProject(projectId: string, folderUri: string): Promise<void> {
		const project = this.projects.find(p => p.id === projectId);
		if (!project) {
			return;
		}

		// Update the stored folder
		(project as { folderUri?: string }).folderUri = folderUri;
		this.saveToDisk();

		if (projectId === this.mainWindowProjectId) {
			// For the main window project, delegate to WindowsMainService
			const mainWindow = this.windowsMainService.getWindows()[0];
			if (mainWindow) {
				const parsed = URI.parse(folderUri);
				const remoteAuthority = parsed.scheme === Schemas.vscodeRemote ? parsed.authority : undefined;
				await this.windowsMainService.open({
					context: OpenContext.API,
					contextWindowId: mainWindow.id,
					cli: this.environmentMainService.args,
					urisToOpen: [{ folderUri: parsed }],
					remoteAuthority,
				});
			}
		} else {
			// For WebContentsView projects, reload the view with the new workspace
			const parsed = URI.parse(folderUri);
			// Extract remoteAuthority from vscode-remote:// URIs (e.g. "ssh-remote+hostname")
			const remoteAuthority = parsed.scheme === Schemas.vscodeRemote ? parsed.authority : undefined;
			await this.reloadProjectView(project, { workspace: this.getWorkspaceIdentifier(parsed), remoteAuthority });
		}
	}

	async reloadProject(projectId: string): Promise<void> {
		const project = this.projects.find(p => p.id === projectId);
		if (!project) {
			return;
		}

		if (projectId === this.mainWindowProjectId) {
			// For the main window, delegate to WindowsMainService reload via lifecycle
			const mainWindow = this.windowsMainService.getWindows()[0];
			if (mainWindow) {
				mainWindow.reload();
			}
		} else {
			// For WebContentsView projects, reload with current configuration
			if (project.folderUri) {
				const parsed = URI.parse(project.folderUri);
				const remoteAuthority = parsed.scheme === Schemas.vscodeRemote ? parsed.authority : undefined;
				await this.reloadProjectView(project, { workspace: this.getWorkspaceIdentifier(parsed), remoteAuthority });
			} else {
				await this.reloadProjectView(project, { workspace: this.getEmptyProjectWorkspace(project.id) });
			}
		}
	}

	async openRemoteInProject(projectId: string, remoteAuthority: string): Promise<void> {
		const project = this.projects.find(p => p.id === projectId);
		if (!project) {
			return;
		}

		console.log(`[ProjectMainService] Opening remote "${remoteAuthority}" in project "${project.name}"`);

		if (projectId === this.mainWindowProjectId) {
			// For main window, open via WindowsMainService
			await this.windowsMainService.open({
				context: OpenContext.API,
				cli: this.environmentMainService.args,
				forceReuseWindow: true,
				remoteAuthority,
			});
		} else {
			// For WebContentsView projects, reload with remote authority only (no local workspace)
			await this.reloadProjectView(project, { remoteAuthority });
		}
	}

	async createProjectWithRemote(name: string, remoteAuthority: string): Promise<IProject> {
		const project = await this.createProject(name);
		console.log(`[ProjectMainService] Created project "${name}" with remote "${remoteAuthority}"`);
		// The view will be created by createProject, then we reload it with the remote
		await this.openRemoteInProject(project.id, remoteAuthority);
		return project;
	}

	private async reloadProjectView(project: IProject, overrides: { workspace?: ISingleFolderWorkspaceIdentifier; remoteAuthority?: string }): Promise<void> {
		const pv = this.projectViews.get(project.id);
		if (!pv) {
			return;
		}

		const configuration: INativeWindowConfiguration = {
			...this.environmentMainService.args,

			windowId: pv.view.webContents.id,
			machineId: '',
			sqmId: '',
			devDeviceId: '',

			mainPid: process.pid,

			appRoot: this.environmentMainService.appRoot,
			execPath: process.execPath,
			codeCachePath: this.environmentMainService.codeCachePath,

			profiles: {
				home: this.userDataProfilesMainService.profilesHome,
				all: this.userDataProfilesMainService.profiles,
				profile: this.userDataProfilesMainService.defaultProfile,
			},

			homeDir: this.environmentMainService.userHome.fsPath,
			tmpDir: this.environmentMainService.tmpDir.fsPath,
			userDataDir: this.environmentMainService.userDataPath,

			workspace: overrides.workspace,
			remoteAuthority: overrides.remoteAuthority,
			userEnv: {},

			nls: {
				messages: getNLSMessages(),
				language: getNLSLanguage()
			},

			logLevel: this.loggerService.getLogLevel(),
			loggers: this.loggerService.getGlobalLoggers(),
			logsPath: this.environmentMainService.logsHome.fsPath,

			product,
			isInitialStartup: false,
			perfMarks: getMarks(),
			os: { release: release(), hostname: hostname(), arch: arch() },

			autoDetectHighContrast: true,
			autoDetectColorScheme: false,
			colorScheme: { dark: true, highContrast: false },
			policiesData: this.policyService.serialize(),

			isPortable: this.environmentMainService.isPortable,

			cssModules: this.cssDevelopmentService.isEnabled ? await this.cssDevelopmentService.getCssModules() : undefined,
		};

		pv.configUrl.update(configuration);

		const workbenchUrl = FileAccess.asBrowserUri(
			`vs/code/electron-browser/workbench/workbench${this.environmentMainService.isBuilt ? '' : '-dev'}.html`
		).toString(true);
		console.log(`[ProjectView:${project.name}] Reloading, workspace: ${JSON.stringify(configuration.workspace)}, remoteAuthority: ${configuration.remoteAuthority ?? 'none'}`);
		pv.view.webContents.once('did-finish-load', () => {
			console.log(`[ProjectView:${project.name}] did-finish-load after reload`);
			pv.view.setVisible(true);
			pv.view.webContents.focus();
		});
		pv.view.webContents.once('did-fail-load', (_event: Electron.Event, errorCode: number, errorDescription: string) => {
			console.log(`[ProjectView:${project.name}] did-fail-load: ${errorCode} ${errorDescription}`);
		});
		pv.view.webContents.loadURL(workbenchUrl);
	}

	/**
	 * Restores projects from disk after the first window has opened.
	 * Called from app.ts afterWindowOpen().
	 */
	async restoreProjects(): Promise<void> {
		console.log(`[ProjectMainService] restoreProjects() called, ${this.projects.length} project(s)`);
		if (this.projects.length === 0) {
			return;
		}

		const mainWindow = this.windowsMainService.getWindows()[0];
		if (!mainWindow?.win) {
			console.log('[ProjectMainService] No main window available for project restoration');
			return;
		}

		// First project adopts the main window
		this.mainWindowProjectId = this.projects[0].id;
		console.log(`[ProjectMainService] Restoring ${this.projects.length} project(s), main window → "${this.projects[0].name}"`);

		// Create WebContentsViews for additional projects
		for (let i = 1; i < this.projects.length; i++) {
			await this.createViewForProject(this.projects[i], mainWindow.win);
		}

		// Set active project
		if (!this.activeProjectId) {
			this.activeProjectId = this.projects[0].id;
		}

		// Show the active project's view
		if (this.activeProjectId !== this.mainWindowProjectId) {
			await this.switchToProject(this.activeProjectId);
		}
	}

	/**
	 * Associates the main window with the first project (used during startup).
	 */
	registerWindowForProject(projectId: string, _windowId: number): void {
		if (!this.mainWindowProjectId) {
			this.mainWindowProjectId = projectId;
		}
	}

	private getWorkspaceIdentifier(folderUri: URI) {
		if (folderUri.scheme === Schemas.file) {
			try {
				const stat = fs.statSync(folderUri.fsPath);
				return getSingleFolderWorkspaceIdentifier(folderUri, stat);
			} catch {
				return undefined;
			}
		}
		return getSingleFolderWorkspaceIdentifier(folderUri);
	}

	private getEmptyProjectWorkspace(projectId: string): ISingleFolderWorkspaceIdentifier | undefined {
		// Create a unique folder per project so each gets independent workspaceStorage
		const projectDir = path.join(this.environmentMainService.userDataPath, 'project-workspaces', projectId);
		fs.mkdirSync(projectDir, { recursive: true });
		const folderUri = URI.file(projectDir);
		const stat = fs.statSync(projectDir);
		return getSingleFolderWorkspaceIdentifier(folderUri, stat);
	}

	private async createViewForProject(project: IProject, browserWindow: Electron.BrowserWindow): Promise<void> {
		const disposables = new DisposableStore();

		// Create IPC Object URL for passing configuration to the renderer
		const configObjectUrl = this.protocolMainService.createIPCObjectUrl<INativeWindowConfiguration>();
		disposables.add(configObjectUrl);

		// Build webPreferences matching CodeWindow
		const webPreferences: Electron.WebPreferences = {
			preload: FileAccess.asFileUri('vs/base/parts/sandbox/electron-browser/preload.js').fsPath,
			additionalArguments: [`--vscode-window-config=${configObjectUrl.resource.toString()}`],
			v8CacheOptions: this.environmentMainService.useCodeCache ? 'bypassHeatCheck' : 'none',
			enableWebSQL: false,
			spellcheck: false,
			autoplayPolicy: 'user-gesture-required',
			enableBlinkFeatures: 'HighlightAPI',
			sandbox: true,
		};

		// Create the WebContentsView
		const view = new WebContentsView({ webPreferences });
		view.setBackgroundColor('#1e1e1e');

		// Build the configuration for the renderer
		const defaultProfile = this.userDataProfilesMainService.defaultProfile;
		const configuration: INativeWindowConfiguration = {
			...this.environmentMainService.args,

			windowId: view.webContents.id,
			machineId: '',
			sqmId: '',
			devDeviceId: '',

			mainPid: process.pid,

			appRoot: this.environmentMainService.appRoot,
			execPath: process.execPath,
			codeCachePath: this.environmentMainService.codeCachePath,

			profiles: {
				home: this.userDataProfilesMainService.profilesHome,
				all: this.userDataProfilesMainService.profiles,
				profile: defaultProfile,
			},

			homeDir: this.environmentMainService.userHome.fsPath,
			tmpDir: this.environmentMainService.tmpDir.fsPath,
			userDataDir: this.environmentMainService.userDataPath,

			workspace: project.folderUri ? this.getWorkspaceIdentifier(URI.parse(project.folderUri)) : this.getEmptyProjectWorkspace(project.id),
			remoteAuthority: project.folderUri && URI.parse(project.folderUri).scheme === Schemas.vscodeRemote ? URI.parse(project.folderUri).authority : undefined,
			userEnv: {},

			nls: {
				messages: getNLSMessages(),
				language: getNLSLanguage()
			},

			logLevel: this.loggerService.getLogLevel(),
			loggers: this.loggerService.getGlobalLoggers(),
			logsPath: this.environmentMainService.logsHome.fsPath,

			product,
			isInitialStartup: false,
			perfMarks: getMarks(),
			os: { release: release(), hostname: hostname(), arch: arch() },

			autoDetectHighContrast: true,
			autoDetectColorScheme: false,
			colorScheme: { dark: true, highContrast: false },
			policiesData: this.policyService.serialize(),

			isPortable: this.environmentMainService.isPortable,

			cssModules: this.cssDevelopmentService.isEnabled ? await this.cssDevelopmentService.getCssModules() : undefined,
		};

		// Update the IPC Object URL with the configuration
		configObjectUrl.update(configuration);

		// Add the view to the browser window
		browserWindow.contentView.addChildView(view);

		// Size the view to fill the window
		const [width, height] = browserWindow.getContentSize();
		view.setBounds({ x: 0, y: 0, width, height });

		// Listen for window resize to update view bounds
		const resizeHandler = () => {
			const [w, h] = browserWindow.getContentSize();
			view.setBounds({ x: 0, y: 0, width: w, height: h });
		};
		browserWindow.on('resize', resizeHandler);
		disposables.add({ dispose: () => browserWindow.removeListener('resize', resizeHandler) });

		// Debug: log renderer errors and page load
		view.webContents.on('console-message', (_event, level, message, line, sourceId) => {
			if (level >= 2) {
				this.logService.warn(`[ProjectView:${project.name}][${level}] ${message} (${sourceId}:${line})`);
			}
		});
		view.webContents.on('did-fail-load', (_event, errorCode, errorDescription) => {
			this.logService.error(`[ProjectView:${project.name}] Failed to load: ${errorCode} ${errorDescription}`);
		});

		// Load the workbench HTML
		const workbenchUrl = FileAccess.asBrowserUri(
			`vs/code/electron-browser/workbench/workbench${this.environmentMainService.isBuilt ? '' : '-dev'}.html`
		).toString(true);
		this.logService.info(`[ProjectView:${project.name}] Loading workbench: ${workbenchUrl}`);
		view.webContents.loadURL(workbenchUrl);

		this.logService.info(`[ProjectMainService] Created WebContentsView for project "${project.name}"`);

		this.projectViews.set(project.id, {
			view,
			disposables,
			configUrl: configObjectUrl,
		});
	}

	override dispose(): void {
		// Save state before shutdown
		this.saveToDisk();

		// Remove and dispose all project views
		const mainWindow = this.windowsMainService.getWindows()[0];
		for (const [, pv] of this.projectViews) {
			if (mainWindow?.win) {
				mainWindow.win.contentView.removeChildView(pv.view);
			}
			pv.configUrl.dispose();
			pv.disposables.dispose();
		}
		this.projectViews.clear();
		super.dispose();
	}
}
