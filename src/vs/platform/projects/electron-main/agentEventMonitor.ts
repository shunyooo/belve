/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import * as cp from 'child_process';
import { Disposable } from '../../../base/common/lifecycle.js';
import { ILogService } from '../../log/common/log.js';
import { type IAgentSession, IProjectMainService, ProjectStatus } from '../common/projects.js';
import { ensureRemoteAgentHooks } from './agentHooksSetup.js';

/** dock-code agent event file path */
export const AGENT_EVENTS_FILE = path.join(os.tmpdir(), 'dock-code-agent-events');

interface AgentEvent {
	source: string;
	eventType: string;
	status: string;
	projectPath: string;
	sessionId: string;
	message: string;
}

/**
 * Tracks per-session agent status and resolves a project-level aggregate status.
 *
 * Priority: running > waiting > error > completed > idle
 * If any session is running, project is running. Etc.
 */
class ProjectSessionTracker {
	private readonly sessions = new Map<string, ProjectStatus>();

	update(sessionId: string, status: ProjectStatus): void {
		if (status === ProjectStatus.Idle) {
			this.sessions.delete(sessionId);
		} else {
			this.sessions.set(sessionId, status);
		}
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
			for (const [, status] of this.sessions) {
				if (status === s) {
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
		return Array.from(this.sessions.entries()).map(([sessionId, status]) => ({ sessionId, status }));
	}
}

/**
 * Monitors the dock-code agent events file for status changes from Claude Code
 * and other AI agents. Updates project statuses in ProjectMainService accordingly.
 */
export class AgentEventMonitor extends Disposable {

	private watcher: fs.FSWatcher | undefined;
	private fileOffset = 0;
	/** Per-project session trackers */
	private readonly trackers = new Map<string, ProjectSessionTracker>();

	/** Active relay processes for remote projects */
	private readonly relayProcesses = new Map<string, cp.ChildProcess>();

	constructor(
		private readonly projectService: IProjectMainService,
		private readonly logService: ILogService,
	) {
		super();
		this.start();
		this.startRemoteRelays();

		// Watch for new projects being added (e.g. new remote connections)
		this._register(this.projectService.onDidChangeProjects(() => this.startRemoteRelays()));
	}

	private start(): void {
		// Create file if it doesn't exist
		try {
			if (!fs.existsSync(AGENT_EVENTS_FILE)) {
				fs.writeFileSync(AGENT_EVENTS_FILE, '', 'utf8');
			}
			// Start from end of file (only process new events)
			const stat = fs.statSync(AGENT_EVENTS_FILE);
			this.fileOffset = stat.size;
		} catch (err) {
			this.logService.error('[AgentEventMonitor] Failed to initialize events file:', err);
			return;
		}

		this.logService.info(`[AgentEventMonitor] Watching ${AGENT_EVENTS_FILE}`);

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

		// Fallback: if no folderUri match, apply to active project
		if (!projectId) {
			const active = await this.projectService.getActiveProject();
			projectId = active?.id;
		}

		if (!projectId) {
			return;
		}

		// Track per-session status
		let tracker = this.trackers.get(projectId);
		if (!tracker) {
			tracker = new ProjectSessionTracker();
			this.trackers.set(projectId, tracker);
		}
		tracker.update(event.sessionId, status);

		const aggregate = tracker.getAggregateStatus();
		const sessions = tracker.getSessions();
		this.logService.info(`[AgentEventMonitor] project=${projectId}: session=${event.sessionId} ${event.status}, aggregate=${aggregate} (${tracker.sessionCount} sessions)`);
		await this.projectService.updateProjectStatus(projectId, aggregate);
		await this.projectService.updateAgentSessions(projectId, sessions);
	}

	private mapStatus(eventStatus: string): ProjectStatus | undefined {
		switch (eventStatus) {
			case 'running': return ProjectStatus.Running;
			case 'waiting': return ProjectStatus.Waiting;
			case 'completed': return ProjectStatus.Completed;
			case 'session_start': return ProjectStatus.Running;
			case 'session_end': return ProjectStatus.Idle;
			default: return undefined;
		}
	}

	private pathMatches(folderUri: string, projectPath: string): boolean {
		// folderUri might be file:///path or just /path
		const normalized = folderUri.replace(/^file:\/\//, '');
		return normalized === projectPath || normalized.endsWith(projectPath) || projectPath.endsWith(normalized);
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
		this.watcher?.close();
		for (const [, proc] of this.relayProcesses) {
			proc.kill();
		}
		this.relayProcesses.clear();
		super.dispose();
	}
}
