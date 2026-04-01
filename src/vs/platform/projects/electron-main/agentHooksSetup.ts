/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import * as cp from 'child_process';
import { ILogService } from '../../log/common/log.js';
import { AGENT_EVENTS_FILE } from './agentEventMonitor.js';

const CLAUDE_SETTINGS_PATH = path.join(os.homedir(), '.claude', 'settings.json');
const DOCK_CODE_HOOK_MARKER = 'dock-code-agent-events';

/** Path where dock-code-agent-hook script will be installed */
const HOOK_SCRIPT_INSTALL_PATH = path.join(os.homedir(), '.local', 'bin', 'dock-code-agent-hook');

/**
 * The hooks dock-code needs in Claude Code's settings.json.
 * Each hook calls `dock-code-agent-hook <status> <message>`.
 */
function getDockCodeHooks(): Record<string, object> {
	const cmd = (status: string, message: string) =>
		`dock-code-agent-hook ${status} ${message}`;
	return {
		UserPromptSubmit: {
			hooks: [{ type: 'command', command: cmd('running', 'Generating') }]
		},
		Notification: {
			hooks: [{ type: 'command', command: cmd('waiting', 'notification') }]
		},
		Stop: {
			hooks: [{ type: 'command', command: cmd('completed', 'Done') }]
		},
		SessionStart: {
			hooks: [{ type: 'command', command: cmd('session_start', 'start') }]
		},
		SessionEnd: {
			hooks: [{ type: 'command', command: cmd('session_end', 'end') }]
		},
	};
}

/**
 * Install the dock-code-agent-hook script to ~/.local/bin/
 */
function installHookScript(logService: ILogService): void {
	const thisDir = import.meta.dirname;
	const sourcePath = path.join(thisDir, '..', '..', '..', '..', 'scripts', 'dock-code-agent-hook');
	// In dev mode, import.meta.dirname is in out/, source is in repo root
	const devSourcePath = path.resolve(thisDir, '..', '..', '..', '..', '..', 'scripts', 'dock-code-agent-hook');
	const src = fs.existsSync(sourcePath) ? sourcePath : devSourcePath;

	if (!fs.existsSync(src)) {
		logService.warn('[AgentHooksSetup] dock-code-agent-hook script not found at', src);
		return;
	}

	try {
		fs.mkdirSync(path.dirname(HOOK_SCRIPT_INSTALL_PATH), { recursive: true });
		fs.copyFileSync(src, HOOK_SCRIPT_INSTALL_PATH);
		fs.chmodSync(HOOK_SCRIPT_INSTALL_PATH, 0o755);
		logService.info('[AgentHooksSetup] Installed dock-code-agent-hook to', HOOK_SCRIPT_INSTALL_PATH);
	} catch (err) {
		logService.error('[AgentHooksSetup] Failed to install hook script:', err);
	}
}

/**
 * Ensures Claude Code's settings.json has dock-code hooks configured.
 * Adds hooks alongside any existing ones without disrupting them.
 */
export function ensureAgentHooks(logService: ILogService): void {
	// Install the hook script to ~/.local/bin/
	installHookScript(logService);

	try {
		// Read existing settings
		let settings: Record<string, unknown> = {};
		if (fs.existsSync(CLAUDE_SETTINGS_PATH)) {
			const content = fs.readFileSync(CLAUDE_SETTINGS_PATH, 'utf8');
			settings = JSON.parse(content);
		} else {
			// Create .claude directory if needed
			fs.mkdirSync(path.dirname(CLAUDE_SETTINGS_PATH), { recursive: true });
		}

		// Check if dock-code hooks already exist
		const hooks = (settings.hooks ?? {}) as Record<string, unknown[]>;
		const hasMarker = JSON.stringify(hooks).includes(DOCK_CODE_HOOK_MARKER);
		if (hasMarker) {
			logService.info('[AgentHooksSetup] dock-code hooks already configured');
			return;
		}

		// Add dock-code hooks to each event type
		const dockCodeHooks = getDockCodeHooks();
		for (const [eventType, hookDef] of Object.entries(dockCodeHooks)) {
			if (!hooks[eventType]) {
				hooks[eventType] = [];
			}
			(hooks[eventType] as unknown[]).push(hookDef);
		}

		settings.hooks = hooks;

		// Write back
		fs.writeFileSync(CLAUDE_SETTINGS_PATH, JSON.stringify(settings, null, 2), 'utf8');
		logService.info('[AgentHooksSetup] Added dock-code hooks to Claude Code settings');
	} catch (err) {
		logService.error('[AgentHooksSetup] Failed to configure hooks:', err);
	}
}

/**
 * Ensures Claude Code hooks are configured on a remote host via SSH.
 * The remote hooks write to /tmp/dock-code-agent-events (fixed path),
 * which gets relayed back to local by AgentEventMonitor.
 */
export function ensureRemoteAgentHooks(host: string, logService: ILogService): void {
	const marker = DOCK_CODE_HOOK_MARKER;

	// Same hook commands as local (dock-code-agent-hook is installed on remote too)
	const cmd = (status: string, message: string) =>
		`dock-code-agent-hook ${status} ${message}`;
	const hooksJson = JSON.stringify({
		UserPromptSubmit: { hooks: [{ type: 'command', command: cmd('running', 'Generating') }] },
		Notification: { hooks: [{ type: 'command', command: cmd('waiting', 'notification') }] },
		Stop: { hooks: [{ type: 'command', command: cmd('completed', 'Done') }] },
		SessionStart: { hooks: [{ type: 'command', command: cmd('session_start', 'start') }] },
		SessionEnd: { hooks: [{ type: 'command', command: cmd('session_end', 'end') }] },
	});

	// Step 1: scp the hook script to remote
	const remoteThisDir = import.meta.dirname;
	const remoteSrcPath = path.join(remoteThisDir, '..', '..', '..', '..', 'scripts', 'dock-code-agent-hook');
	const remoteDevSrcPath = path.resolve(remoteThisDir, '..', '..', '..', '..', '..', 'scripts', 'dock-code-agent-hook');
	const src = fs.existsSync(remoteSrcPath) ? remoteSrcPath : remoteDevSrcPath;

	if (fs.existsSync(src)) {
		const scpProc = cp.spawn('scp', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'BatchMode=yes',
			src,
			`${host}:.local/bin/dock-code-agent-hook`,
		], { stdio: ['ignore', 'pipe', 'pipe'] });
		scpProc.on('close', (code) => {
			if (code === 0) {
				logService.info(`[AgentHooksSetup] Installed hook script on ${host}`);
			} else {
				logService.warn(`[AgentHooksSetup] Failed to scp hook script to ${host}`);
			}
		});
	}

	// Step 2: Configure hooks in remote ~/.claude/settings.json
	const remoteScript = `
		const fs = require('fs');
		const path = require('path');
		const settingsDir = path.join(require('os').homedir(), '.claude');
		const settingsPath = path.join(settingsDir, 'settings.json');
		let settings = {};
		try { fs.mkdirSync(settingsDir, { recursive: true, mode: 0o755 }); } catch {}
		try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch {}
		const hooks = settings.hooks || {};
		if (JSON.stringify(hooks).includes('${marker}')) { process.exit(0); }
		const newHooks = ${hooksJson};
		for (const [k, v] of Object.entries(newHooks)) {
			if (!hooks[k]) hooks[k] = [];
			hooks[k].push(v);
		}
		settings.hooks = hooks;
		fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), { mode: 0o644 });
	`.replace(/\n\t+/g, ' ').trim();

	const sshArgs = [
		'-o', 'StrictHostKeyChecking=accept-new',
		'-o', 'ConnectTimeout=10',
		'-o', 'BatchMode=yes',
		host,
		'mkdir -p ~/.local/bin && chmod +x ~/.local/bin/dock-code-agent-hook 2>/dev/null; test -w ~/.claude/settings.json 2>/dev/null || (test -f ~/.claude/settings.json && sudo chown `whoami` ~/.claude/settings.json 2>/dev/null); node -e \'' + remoteScript.replace(/'/g, '\'\\\'\'') + '\'',
	];

	logService.info(`[AgentHooksSetup] Configuring remote hooks on ${host}`);

	const proc = cp.spawn('ssh', sshArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
	let stderr = '';
	proc.stderr?.on('data', (d: Buffer) => { stderr += d.toString(); });
	proc.on('close', (code) => {
		if (code === 0) {
			logService.info(`[AgentHooksSetup] Remote hooks configured on ${host}`);
		} else {
			logService.warn(`[AgentHooksSetup] Remote hooks setup failed on ${host} (code ${code}): ${stderr.substring(0, 200)}`);
		}
	});
}
