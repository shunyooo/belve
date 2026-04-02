/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import * as cp from 'child_process';
import { ILogService } from '../../log/common/log.js';

const CLAUDE_SETTINGS_PATH = path.join(os.homedir(), '.claude', 'settings.json');
const DOCK_CODE_HOOK_MARKER = 'dock-code-agent-events';
/** Marker for the current hook version. Update when hook commands change to trigger re-registration. */
const DOCK_CODE_HOOK_VERSION_MARKER = 'dock-code-v7';

/**
 * Generate the inline node command for a hook.
 * Embeds the full script logic so it works everywhere (local, SSH, DevContainer)
 * without requiring an external script file on PATH.
 */
function makeHookCommand(status: string, message: string): string {
	// Compact inline script — writes agent event to dock-code events file.
	// Only runs when DOCK_CODE_SESSION env var is set (i.e. inside dock-code's PaneContainer terminal).
	const script = [
		`var _v="${DOCK_CODE_HOOK_VERSION_MARKER}"`,
		'if(!process.env.DOCK_CODE_SESSION)process.exit(0)',
		'let d=""',
		'process.stdin.on("data",c=>d+=c)',
		`process.stdin.on("end",()=>{try{const j=JSON.parse(d);require("fs").appendFileSync("/tmp/dock-code-agent-events",JSON.stringify({source:"terminal",eventType:"claude-code",status:"${status}",projectPath:j.cwd,sessionId:j.session_id,paneId:process.env.DOCK_CODE_PANE_ID||"",message:"${message}"})+"\\n")}catch{}})`,
	].join(';');
	return `node -e '${script}'`;
}

/**
 * Generate a combined hook command for UserPromptSubmit that:
 * 1. Writes the "running" status event
 * 2. Spawns a background `claude -p` to generate a ≤10 char session label
 *
 * Combined into one command because Claude Code hooks within a group share stdin,
 * so both operations must read the same stdin data in one process.
 */
function makeUserPromptSubmitCommand(): string {
	const script = [
		`var _v="${DOCK_CODE_HOOK_VERSION_MARKER}"`,
		'if(!process.env.DOCK_CODE_SESSION)process.exit(0)',
		'let d=""',
		'process.stdin.on("data",c=>d+=c)',
		'process.stdin.on("end",()=>{try{const j=JSON.parse(d)',
		'const fs=require("fs"),p=require("path"),cp=require("child_process")',
		'const pid=process.env.DOCK_CODE_PANE_ID||""',
		// Debug: dump raw stdin to file for inspection
		'fs.writeFileSync("/tmp/dock-code-hook-debug.json",d)',
		// Write status event
		'fs.appendFileSync("/tmp/dock-code-agent-events",JSON.stringify({source:"terminal",eventType:"claude-code",status:"running",projectPath:j.cwd,sessionId:j.session_id,paneId:pid,message:"Generating"})+"\\n")',
		// Label generation (background, first prompt only)
		'const mk=p.join(require("os").tmpdir(),"dock-code-label-"+j.session_id)',
		'fs.writeFileSync("/tmp/dock-code-hook-debug2.txt","mk="+mk+" exists="+fs.existsSync(mk)+" prompt="+(j.prompt||"NONE"))',
		'if(!fs.existsSync(mk)){fs.writeFileSync(mk,"")',
		'const prompt=j.prompt||""',
		'if(prompt){const sid=j.session_id,cwd=j.cwd',
		'const q="Generate a label (max 10 characters, in the same language as the input) that summarizes this task. Output ONLY the label, nothing else: "+prompt.substring(0,500)',
		'const env=Object.assign({},process.env,{DOCK_CODE_SESSION:""})',
		'fs.writeFileSync("/tmp/dock-code-hook-debug3.txt","spawning claude")',
		'const c=cp.spawn("claude",["--model","haiku","-p",q],{stdio:["ignore","pipe","pipe"],env:env})',
		'let o=""',
		'c.stdout.on("data",b=>o+=b)',
		'c.stderr.on("data",b=>fs.appendFileSync("/tmp/dock-code-hook-debug4.txt",b))',
		'c.on("close",()=>{const label=o.trim().substring(0,15)',
		'fs.writeFileSync("/tmp/dock-code-hook-debug5.txt","label="+label)',
		'if(label)fs.appendFileSync("/tmp/dock-code-agent-events",JSON.stringify({source:"terminal",eventType:"claude-code",status:"label",projectPath:cwd,sessionId:sid,paneId:pid,message:label})+"\\n")})}}',
		'}catch(e){fs.writeFileSync("/tmp/dock-code-hook-error.txt",String(e))}})',
	].join(';');
	return `node -e '${script}'`;
}

/**
 * The hooks dock-code needs in Claude Code's settings.json.
 */
/**
 * Returns dock-code hooks. Values are either a single hook group object
 * or an array of hook groups (when multiple hooks need separate stdin pipes).
 */
function getDockCodeHooks(): Record<string, object | object[]> {
	return {
		UserPromptSubmit: {
			hooks: [{ type: 'command', command: makeUserPromptSubmitCommand() }]
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
 * Ensures Claude Code's settings.json has up-to-date dock-code hooks configured.
 * If old hooks exist (without DOCK_CODE_SESSION guard), they are replaced.
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

		const hooks = (settings.hooks ?? {}) as Record<string, unknown[]>;
		const hooksStr = JSON.stringify(hooks);
		const hasMarker = hooksStr.includes(DOCK_CODE_HOOK_MARKER);
		const hasCurrentVersion = hooksStr.includes(DOCK_CODE_HOOK_VERSION_MARKER);

		if (hasMarker && hasCurrentVersion) {
			logService.info('[AgentHooksSetup] dock-code hooks already up to date');
			return;
		}

		// Remove old dock-code hooks before adding new ones
		if (hasMarker && !hasCurrentVersion) {
			logService.info('[AgentHooksSetup] Replacing outdated dock-code hooks');
			removeDockCodeHooks(hooks);
		}

		// Add dock-code hooks to each event type
		const dockCodeHooks = getDockCodeHooks();
		for (const [eventType, hookDef] of Object.entries(dockCodeHooks)) {
			if (!hooks[eventType]) {
				hooks[eventType] = [];
			}
			if (Array.isArray(hookDef)) {
				for (const entry of hookDef) {
					(hooks[eventType] as unknown[]).push(entry);
				}
			} else {
				(hooks[eventType] as unknown[]).push(hookDef);
			}
		}

		settings.hooks = hooks;

		// Write back
		fs.writeFileSync(CLAUDE_SETTINGS_PATH, JSON.stringify(settings, null, 2), 'utf8');
		logService.info('[AgentHooksSetup] Configured dock-code hooks in Claude Code settings');
	} catch (err) {
		logService.error('[AgentHooksSetup] Failed to configure hooks:', err);
	}
}

/**
 * Removes all dock-code hooks from the hooks object (identified by the marker string).
 */
function removeDockCodeHooks(hooks: Record<string, unknown[]>): void {
	for (const [eventType, hookList] of Object.entries(hooks)) {
		if (!Array.isArray(hookList)) {
			continue;
		}
		hooks[eventType] = hookList.filter(
			(hook) => !JSON.stringify(hook).includes(DOCK_CODE_HOOK_MARKER)
		);
		if (hooks[eventType].length === 0) {
			delete hooks[eventType];
		}
	}
}

/**
 * Ensures Claude Code hooks are configured on a remote host via SSH.
 * The remote hooks write to /tmp/dock-code-agent-events (fixed path),
 * which gets relayed back to local by AgentEventMonitor.
 */
export function ensureRemoteAgentHooks(host: string, logService: ILogService): void {
	const marker = DOCK_CODE_HOOK_MARKER;
	const versionMarker = DOCK_CODE_HOOK_VERSION_MARKER;

	// Same inline hook commands as local — works in any environment
	const hooksJson = JSON.stringify(getDockCodeHooks());

	// Configure hooks in remote ~/.claude/settings.json
	// Also handles upgrading old hooks (without DOCK_CODE_SESSION guard)
	const remoteScript = `
		const fs = require('fs');
		const path = require('path');
		const settingsDir = path.join(require('os').homedir(), '.claude');
		const settingsPath = path.join(settingsDir, 'settings.json');
		let settings = {};
		try { fs.mkdirSync(settingsDir, { recursive: true, mode: 0o755 }); } catch {}
		try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch {}
		const hooks = settings.hooks || {};
		const s = JSON.stringify(hooks);
		if (s.includes('${marker}') && s.includes('${versionMarker}')) { process.exit(0); }
		if (s.includes('${marker}')) {
			for (const [k, v] of Object.entries(hooks)) {
				if (!Array.isArray(v)) continue;
				hooks[k] = v.filter(h => !JSON.stringify(h).includes('${marker}'));
				if (hooks[k].length === 0) delete hooks[k];
			}
		}
		const newHooks = ${hooksJson};
		for (const [k, v] of Object.entries(newHooks)) {
			if (!hooks[k]) hooks[k] = [];
			if (Array.isArray(v)) { for (const e of v) hooks[k].push(e); }
			else hooks[k].push(v);
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
		'  cat ~/.claude/settings.json | docker exec -i $cid tee /root/.claude/settings.json >/dev/null 2>/dev/null &&',
		'  echo "synced $cid";',
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
	let stderr = '';
	proc.stdout?.on('data', (d: Buffer) => { output += d.toString(); });
	proc.stderr?.on('data', (d: Buffer) => { stderr += d.toString(); });
	proc.on('close', (code) => {
		if (code === 0 && output.trim()) {
			logService.info(`[AgentHooksSetup] Synced settings to containers: ${output.trim()}`);
		} else if (code !== 0) {
			logService.warn(`[AgentHooksSetup] Container sync failed (code ${code}): ${stderr.substring(0, 200)}`);
		} else {
			logService.info(`[AgentHooksSetup] Container sync: no containers to sync`);
		}
	});
	proc.on('error', (err) => {
		logService.error(`[AgentHooksSetup] Container sync error:`, err);
	});
}
