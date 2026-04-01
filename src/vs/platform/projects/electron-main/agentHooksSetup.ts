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

/**
 * Generate the inline node command for a hook.
 * Embeds the full script logic so it works everywhere (local, SSH, DevContainer)
 * without requiring an external script file on PATH.
 */
function makeHookCommand(status: string, message: string): string {
	// Compact inline script — writes agent event to dock-code events file.
	// No env var check — runs in any environment where dock-code hooks are configured.
	const script = [
		'let d=""',
		'process.stdin.on("data",c=>d+=c)',
		`process.stdin.on("end",()=>{try{const j=JSON.parse(d);require("fs").appendFileSync("/tmp/dock-code-agent-events",JSON.stringify({source:"terminal",eventType:"claude-code",status:"${status}",projectPath:j.cwd,sessionId:j.session_id,message:"${message}"})+"\\n")}catch{}})`,
	].join(';');
	return `node -e '${script}'`;
}

/**
 * The hooks dock-code needs in Claude Code's settings.json.
 */
function getDockCodeHooks(): Record<string, object> {
	return {
		UserPromptSubmit: {
			hooks: [{ type: 'command', command: makeHookCommand('running', 'Generating') }]
		},
		Notification: {
			hooks: [{ type: 'command', command: makeHookCommand('waiting', 'notification') }]
		},
		Stop: {
			hooks: [{ type: 'command', command: makeHookCommand('completed', 'Done') }]
		},
		SessionStart: {
			hooks: [{ type: 'command', command: makeHookCommand('session_start', 'start') }]
		},
		SessionEnd: {
			hooks: [{ type: 'command', command: makeHookCommand('session_end', 'end') }]
		},
	};
}

/**
 * Ensures Claude Code's settings.json has dock-code hooks configured.
 * Adds hooks alongside any existing ones without disrupting them.
 */
export function ensureAgentHooks(logService: ILogService): void {
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

	// Same inline hook commands as local — works in any environment
	const hooksJson = JSON.stringify(getDockCodeHooks());

	// Configure hooks in remote ~/.claude/settings.json
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
		const content = JSON.stringify(settings, null, 2);
		const fd = fs.openSync(settingsPath, 'w');
		fs.writeSync(fd, content);
		fs.closeSync(fd);
	`.replace(/\n\t+/g, ' ').trim();

	const sshArgs = [
		'-o', 'StrictHostKeyChecking=accept-new',
		'-o', 'ConnectTimeout=10',
		'-o', 'BatchMode=yes',
		host,
		'test -w ~/.claude/settings.json 2>/dev/null || (test -f ~/.claude/settings.json && sudo chown `whoami` ~/.claude/settings.json 2>/dev/null); node -e \'' + remoteScript.replace(/'/g, '\'\\\'\'') + '\'',
	];

	logService.info(`[AgentHooksSetup] Configuring remote hooks on ${host}`);

	const proc = cp.spawn('ssh', sshArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
	let stderr = '';
	proc.stderr?.on('data', (d: Buffer) => { stderr += d.toString(); });
	proc.on('close', (code) => {
		if (code === 0) {
			logService.info(`[AgentHooksSetup] Remote hooks configured on ${host}`);
			// Also sync settings into running containers (Docker bind mount inode issue)
			syncSettingsToContainers(host, logService);
		} else {
			logService.warn(`[AgentHooksSetup] Remote hooks setup failed on ${host} (code ${code}): ${stderr.substring(0, 200)}`);
		}
	});
}

/**
 * After updating settings.json on the SSH host, sync the content into
 * all running Docker containers. This is needed because Docker file-level
 * bind mounts break when the host file is replaced (inode changes).
 */
function syncSettingsToContainers(host: string, logService: ILogService): void {
	const syncCmd = [
		'for cid in $(docker ps -q 2>/dev/null); do',
		'  docker exec $cid test -f /root/.claude/settings.json 2>/dev/null &&',
		'  cat ~/.claude/settings.json | docker exec -i $cid sh -c \'cat > /root/.claude/settings.json\' 2>/dev/null &&',
		'  echo "synced $cid"',
		'done',
	].join(' ');

	const proc = cp.spawn('ssh', [
		'-o', 'StrictHostKeyChecking=accept-new',
		'-o', 'ConnectTimeout=10',
		'-o', 'BatchMode=yes',
		host,
		syncCmd,
	], { stdio: ['ignore', 'pipe', 'pipe'] });

	let output = '';
	proc.stdout?.on('data', (d: Buffer) => { output += d.toString(); });
	proc.on('close', (code) => {
		if (code === 0 && output.trim()) {
			logService.info(`[AgentHooksSetup] Synced settings to containers: ${output.trim()}`);
		}
	});
}
