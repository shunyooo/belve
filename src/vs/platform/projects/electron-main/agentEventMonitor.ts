/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import * as cp from 'child_process';
import electron from 'electron';
import { URI } from '../../../base/common/uri.js';
import { Disposable } from '../../../base/common/lifecycle.js';
import { ILogService } from '../../log/common/log.js';
import { type IAgentSession, IProjectMainService, ProjectStatus } from '../common/projects.js';
import { IWindowsMainService } from '../../windows/electron-main/windows.js';
import { ensureRemoteAgentHooks } from './agentHooksSetup.js';

/** dock-code agent event file path */
export const AGENT_EVENTS_FILE = path.join(os.tmpdir(), 'dock-code-agent-events');

interface AgentEvent {
	source: string;
	eventType: string;
	status: string;
	projectPath: string;
	sessionId: string;
	paneId?: string;
	message: string;
}

/**
 * Tracks per-session agent status and resolves a project-level aggregate status.
 *
 * Priority: running > waiting > error > completed > idle
 * If any session is running, project is running. Etc.
 */
/** Stale threshold for active sessions (Running/Waiting) — 10 minutes */
const ACTIVE_SESSION_TIMEOUT_MS = 10 * 60 * 1000;
/** Stale threshold for terminal sessions (Completed/Error) — 5 minutes */
const TERMINAL_SESSION_TIMEOUT_MS = 5 * 60 * 1000;

interface SessionEntry {
	status: ProjectStatus;
	lastEventTime: number;
	paneId?: string;
	label?: string;
}

class ProjectSessionTracker {
	private readonly sessions = new Map<string, SessionEntry>();

	update(sessionId: string, status: ProjectStatus, paneId?: string): void {
		if (status === ProjectStatus.Idle) {
			this.sessions.delete(sessionId);
		} else {
			const existing = this.sessions.get(sessionId);
			this.sessions.set(sessionId, {
				status,
				lastEventTime: Date.now(),
				paneId: paneId || existing?.paneId,
				label: existing?.label,
			});
		}
	}

	setLabel(sessionId: string, label: string): boolean {
		const entry = this.sessions.get(sessionId);
		if (entry) {
			entry.label = label;
			return true;
		}
		return false;
	}

	/**
	 * Remove zombie sessions that haven't received events within the timeout.
	 * Returns true if any sessions were removed.
	 */
	cleanupStale(): boolean {
		const now = Date.now();
		let changed = false;
		for (const [sessionId, entry] of this.sessions) {
			const age = now - entry.lastEventTime;
			const isActive = entry.status === ProjectStatus.Running || entry.status === ProjectStatus.Waiting;
			const timeout = isActive ? ACTIVE_SESSION_TIMEOUT_MS : TERMINAL_SESSION_TIMEOUT_MS;
			if (age > timeout) {
				this.sessions.delete(sessionId);
				changed = true;
			}
		}
		return changed;
	}

	/** Get the highest-priority status across all sessions */
	getAggregateStatus(): ProjectStatus {
		if (this.sessions.size === 0) {
			return ProjectStatus.Idle;
		}
		const priority: ProjectStatus[] = [
			ProjectStatus.Running,
			ProjectStatus.Waiting,
			ProjectStatus.Error,
			ProjectStatus.Completed,
		];
		for (const s of priority) {
			for (const [, entry] of this.sessions) {
				if (entry.status === s) {
					return s;
				}
			}
		}
		return ProjectStatus.Idle;
	}

	get sessionCount(): number {
		return this.sessions.size;
	}

	getSessions(): IAgentSession[] {
		return Array.from(this.sessions.entries()).map(([sessionId, entry]) => ({ sessionId, status: entry.status, paneId: entry.paneId, label: entry.label }));
	}
}

/**
 * Monitors the dock-code agent events file for status changes from Claude Code
 * and other AI agents. Updates project statuses in ProjectMainService accordingly.
 */
/** How often to check for zombie sessions — 60 seconds */
const CLEANUP_INTERVAL_MS = 60 * 1000;

export class AgentEventMonitor extends Disposable {

	private watcher: fs.FSWatcher | undefined;
	private fileOffset = 0;
	/** Per-project session trackers */
	private readonly trackers = new Map<string, ProjectSessionTracker>();

	/** Active relay processes for remote projects */
	private readonly relayProcesses = new Map<string, cp.ChildProcess>();

	/** Previous aggregate status per project, for transition detection */
	private readonly previousStatus = new Map<string, ProjectStatus>();

	/** Suppresses notifications during initial file replay at startup */
	private initializing = true;

	private readonly cleanupTimer: ReturnType<typeof setInterval>;

	constructor(
		private readonly projectService: IProjectMainService,
		private readonly logService: ILogService,
		private readonly windowsMainService: IWindowsMainService,
	) {
		super();
		this.start();
		this.startRemoteRelays();

		// Watch for new projects being added (e.g. new remote connections)
		this._register(this.projectService.onDidChangeProjects(() => this.startRemoteRelays()));

		// Periodically clean up zombie sessions
		this.cleanupTimer = setInterval(() => this.cleanupStaleSessions(), CLEANUP_INTERVAL_MS);
	}

	private start(): void {
		// Truncate events file on startup — old sessions are gone (terminals reinitialized).
		// New sessions will re-register via Claude Code hooks as agents start.
		try {
			fs.writeFileSync(AGENT_EVENTS_FILE, '', 'utf8');
			this.fileOffset = 0;
		} catch (err) {
			this.logService.error('[AgentEventMonitor] Failed to initialize events file:', err);
			return;
		}

		this.logService.info(`[AgentEventMonitor] Watching ${AGENT_EVENTS_FILE} (truncated on startup)`);
		this.initializing = false;

		// Clear any in-memory state from prior lifecycle
		this.trackers.clear();
		this.previousStatus.clear();

		try {
			this.watcher = fs.watch(AGENT_EVENTS_FILE, { persistent: false }, (_eventType) => {
				this.readNewEvents();
			});
		} catch (err) {
			this.logService.error('[AgentEventMonitor] Failed to watch events file:', err);
		}
	}

	private readNewEvents(): void {
		try {
			const stat = fs.statSync(AGENT_EVENTS_FILE);
			if (stat.size <= this.fileOffset) {
				if (stat.size < this.fileOffset) {
					// File was truncated, reset
					this.fileOffset = 0;
				}
				return;
			}

			const fd = fs.openSync(AGENT_EVENTS_FILE, 'r');
			const buffer = Buffer.alloc(stat.size - this.fileOffset);
			fs.readSync(fd, buffer, 0, buffer.length, this.fileOffset);
			fs.closeSync(fd);
			this.fileOffset = stat.size;

			const chunk = buffer.toString('utf8');
			const lines = chunk.split('\n').filter(l => l.trim());

			for (const line of lines) {
				try {
					const event: AgentEvent = JSON.parse(line);
					this.handleEvent(event);
				} catch {
					// Skip malformed lines
				}
			}
		} catch (err) {
			this.logService.error('[AgentEventMonitor] Error reading events:', err);
		}
	}

	private async handleEvent(event: AgentEvent): Promise<void> {
		// Handle label events separately — they update session metadata, not status
		if (event.status === 'label') {
			await this.handleLabelEvent(event);
			return;
		}

		const status = this.mapStatus(event.status);
		if (!status) {
			return;
		}

		// Find project by matching folderUri to event's projectPath
		const projects = await this.projectService.getProjects();
		let projectId: string | undefined;
		for (const project of projects) {
			if (project.folderUri && this.pathMatches(project.folderUri, event.projectPath)) {
				projectId = project.id;
				break;
			}
		}

		// No fallback — if projectPath doesn't match any project, ignore the event.
		// This avoids misattributing events from external terminals.
		if (!projectId) {
			this.logService.debug(`[AgentEventMonitor] No project match for path="${event.projectPath}", ignoring`);
			return;
		}

		// Track per-session status
		let tracker = this.trackers.get(projectId);
		if (!tracker) {
			tracker = new ProjectSessionTracker();
			this.trackers.set(projectId, tracker);
		}
		tracker.update(event.sessionId, status, event.paneId);

		const aggregate = tracker.getAggregateStatus();
		const sessions = tracker.getSessions();
		this.logService.info(`[AgentEventMonitor] project=${projectId}: session=${event.sessionId} ${event.status}, aggregate=${aggregate} (${tracker.sessionCount} sessions)`);
		await this.projectService.updateProjectStatus(projectId, aggregate);
		await this.projectService.updateAgentSessions(projectId, sessions);

		// Desktop notifications on aggregate status transitions
		const previousAggregate = this.previousStatus.get(projectId);
		this.previousStatus.set(projectId, aggregate);
		if (aggregate !== previousAggregate) {
			this.maybeShowNotification(projectId, aggregate, event.message, event.paneId);
		}
	}

	private async handleLabelEvent(event: AgentEvent): Promise<void> {
		const label = event.message;
		if (!label) {
			return;
		}

		// Find which project/tracker owns this session
		for (const [projectId, tracker] of this.trackers) {
			if (tracker.setLabel(event.sessionId, label)) {
				this.logService.info(`[AgentEventMonitor] Label set: session=${event.sessionId} label="${label}"`);
				const sessions = tracker.getSessions();
				await this.projectService.updateAgentSessions(projectId, sessions);
				return;
			}
		}
	}

	//#region Desktop Notifications

	private async maybeShowNotification(projectId: string, status: ProjectStatus, eventMessage: string, paneId?: string): Promise<void> {
		// Don't fire notifications during startup replay of old events
		if (this.initializing) {
			return;
		}

		// Only notify for completed, error, and waiting transitions
		if (status !== ProjectStatus.Completed &&
			status !== ProjectStatus.Error &&
			status !== ProjectStatus.Waiting) {
			return;
		}

		// Don't notify if the window is focused AND this is the active project
		const activeProject = await this.projectService.getActiveProject();
		const focusedWindow = this.windowsMainService.getFocusedWindow();
		if (focusedWindow && activeProject?.id === projectId) {
			return;
		}

		const project = await this.projectService.getProject(projectId);
		if (!project) {
			return;
		}

		if (!electron.Notification.isSupported()) {
			return;
		}

		const body = this.getNotificationBody(status, eventMessage);
		const notification = new electron.Notification({
			title: project.name,
			body,
			silent: status === ProjectStatus.Completed,
		});

		notification.on('click', () => {
			this.handleNotificationClick(projectId, paneId);
		});

		notification.show();
		this.logService.info(`[AgentEventMonitor] Notification: project="${project.name}" status=${status}`);
	}

	private getNotificationBody(status: ProjectStatus, message: string): string {
		switch (status) {
			case ProjectStatus.Completed:
				return message || 'Agent completed';
			case ProjectStatus.Error:
				return message || 'Agent encountered an error';
			case ProjectStatus.Waiting:
				return message || 'Agent is waiting for input';
			default:
				return message || 'Agent status changed';
		}
	}

	private handleNotificationClick(projectId: string, paneId?: string): void {
		this.projectService.switchToProject(projectId);

		// Bring window to front
		const mainWindow = this.windowsMainService.getLastActiveWindow()
			?? this.windowsMainService.getWindows()[0];
		if (mainWindow?.win) {
			if (mainWindow.win.isMinimized()) {
				mainWindow.win.restore();
			}
			mainWindow.win.focus();
		}

		// Focus specific pane (or PaneContainer generically) via IPC
		this.projectService.requestPaneContainerFocus(paneId);
	}

	//#endregion

	//#region Zombie Session Cleanup

	private async cleanupStaleSessions(): Promise<void> {
		for (const [projectId, tracker] of this.trackers) {
			const changed = tracker.cleanupStale();
			if (changed) {
				const aggregate = tracker.getAggregateStatus();
				const sessions = tracker.getSessions();
				this.logService.info(`[AgentEventMonitor] Cleaned up stale sessions for project=${projectId}, aggregate=${aggregate} (${sessions.length} remaining)`);
				await this.projectService.updateProjectStatus(projectId, aggregate);
				await this.projectService.updateAgentSessions(projectId, sessions);

				this.previousStatus.set(projectId, aggregate);
			}
		}
	}

	//#endregion

	private mapStatus(eventStatus: string): ProjectStatus | undefined {
		switch (eventStatus) {
			case 'running': return ProjectStatus.Running;
			case 'waiting': return ProjectStatus.Waiting;
			case 'completed': return ProjectStatus.Completed;
			case 'error': return ProjectStatus.Error;
			case 'session_start': return ProjectStatus.Running;
			case 'session_end': return ProjectStatus.Idle;
			default: return undefined;
		}
	}

	private pathMatches(folderUri: string, projectPath: string): boolean {
		// Extract the path component from the folderUri
		// For file:///path → /path
		// For vscode-remote://authority/path → /path
		let folderPath: string;
		try {
			const uri = URI.parse(folderUri);
			folderPath = uri.path;
		} catch {
			folderPath = folderUri.replace(/^file:\/\//, '');
		}
		return folderPath === projectPath || folderPath.endsWith(projectPath) || projectPath.startsWith(folderPath);
	}

	//#region Remote Event Relay

	/**
	 * For remote projects (SSH/DevContainer), starts a background SSH process
	 * that tails the remote events file and appends to the local events file.
	 * This bridges agent events from containers/remote hosts to local monitoring.
	 */
	private async startRemoteRelays(): Promise<void> {
		const projects = await this.projectService.getProjects();
		for (const project of projects) {
			if (!project.folderUri || this.relayProcesses.has(project.id)) {
				continue;
			}

			const remote = this.parseRemoteAuthority(project.folderUri);
			if (!remote) {
				continue;
			}

			this.startRelay(project.id, project.name, remote);
		}
	}

	private parseRemoteAuthority(folderUri: string): { type: 'ssh'; host: string } | { type: 'dev-container'; host: string; containerId?: string } | undefined {
		// vscode-remote://ssh-remote+hostname/path
		const sshMatch = folderUri.match(/vscode-remote:\/\/ssh-remote\+([^/]+)/);
		if (sshMatch) {
			return { type: 'ssh', host: decodeURIComponent(sshMatch[1]) };
		}

		// vscode-remote://dev-container%2B<hex>/path
		const dcMatch = folderUri.match(/vscode-remote:\/\/dev-container[+%]2[Bb]([^/]+)/);
		if (dcMatch) {
			const hex = decodeURIComponent(dcMatch[1]);
			const payload = Buffer.from(hex, 'hex').toString('utf8');
			const colonIdx = payload.indexOf(':');
			const host = payload.substring(0, colonIdx);
			return { type: 'dev-container', host };
		}

		return undefined;
	}

	private startRelay(projectId: string, projectName: string, remote: { type: string; host: string }): void {
		// Ensure hooks are configured on the remote host
		ensureRemoteAgentHooks(remote.host, this.logService);

		const remoteEventsFile = '/tmp/dock-code-agent-events';

		// Build the tail command based on connection type
		let tailCmd: string;
		if (remote.type === 'dev-container') {
			// For DevContainer: tail events from both the SSH host AND all running containers
			// Hooks run inside the container, so events are written to the container's /tmp/
			tailCmd = [
				// Tail SSH host events (if any local sessions)
				`(touch ${remoteEventsFile} && tail -n 0 -f ${remoteEventsFile} 2>/dev/null &)`,
				// Tail events from all running containers that have the events file
				`for cid in $(docker ps -q 2>/dev/null)`,
				`do (docker exec $cid sh -c 'touch ${remoteEventsFile} && tail -n 0 -f ${remoteEventsFile}' 2>/dev/null &)`,
				`done`,
				// Keep the SSH session alive
				`wait`,
			].join('; ');
		} else {
			// For SSH: just tail the host's events file
			tailCmd = `touch ${remoteEventsFile} && tail -n 0 -f ${remoteEventsFile} 2>/dev/null`;
		}

		const sshArgs = [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ServerAliveInterval=30',
			'-o', 'ConnectTimeout=10',
			'-o', 'BatchMode=yes',
			remote.host,
			tailCmd,
		];

		this.logService.info(`[AgentEventMonitor] Starting remote relay for "${projectName}" via ${remote.host}`);

		const proc = cp.spawn('ssh', sshArgs, {
			stdio: ['ignore', 'pipe', 'pipe'],
		});

		this.relayProcesses.set(projectId, proc);

		// Pipe remote events to local events file
		proc.stdout?.on('data', (data: Buffer) => {
			try {
				fs.appendFileSync(AGENT_EVENTS_FILE, data.toString());
			} catch {
				// Ignore write errors
			}
		});

		proc.stderr?.on('data', (data: Buffer) => {
			const msg = data.toString().trim();
			if (msg) {
				this.logService.warn(`[AgentEventMonitor] Relay stderr (${projectName}): ${msg}`);
			}
		});

		proc.on('close', (code) => {
			this.logService.info(`[AgentEventMonitor] Relay for "${projectName}" exited (code ${code})`);
			this.relayProcesses.delete(projectId);

			// Auto-restart after a delay if still running
			if (!this._store.isDisposed) {
				setTimeout(() => {
					if (!this._store.isDisposed && !this.relayProcesses.has(projectId)) {
						this.startRemoteRelays();
					}
				}, 5000);
			}
		});

		proc.on('error', (err) => {
			this.logService.error(`[AgentEventMonitor] Relay error (${projectName}):`, err);
			this.relayProcesses.delete(projectId);
		});
	}

	//#endregion

	override dispose(): void {
		clearInterval(this.cleanupTimer);
		this.watcher?.close();
		for (const [, proc] of this.relayProcesses) {
			proc.kill();
		}
		this.relayProcesses.clear();
		super.dispose();
	}
}
