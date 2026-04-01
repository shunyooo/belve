/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path'; // eslint-disable-line local/code-import-patterns
import { ILogService } from '../../log/common/log.js';
import { AGENT_EVENTS_FILE } from './agentEventMonitor.js';

const CLAUDE_SETTINGS_PATH = path.join(os.homedir(), '.claude', 'settings.json');
const DOCK_CODE_HOOK_MARKER = 'dock-code-agent-events';

/**
 * Generates the hook command that writes an event to the dock-code events file.
 */
function makeHookCommand(statusField: string, messageField: string): string {
	const eventsFile = AGENT_EVENTS_FILE.replace(/'/g, '\\\'');
	// Only write events when running inside dock-code (DOCK_CODE_SESSION env var is set)
	return `node -e 'if(!process.env.DOCK_CODE_SESSION)process.exit(0);let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{const j=JSON.parse(d);require("fs").appendFileSync("${eventsFile}",JSON.stringify({source:"terminal",eventType:"claude-code",status:${statusField},projectPath:j.cwd,sessionId:j.session_id,message:${messageField}})+"\\n")})'`;
}

/**
 * The hooks dock-code needs in Claude Code's settings.json.
 */
function getDockCodeHooks(): Record<string, object> {
	return {
		UserPromptSubmit: {
			hooks: [{ type: 'command', command: makeHookCommand('"running"', '"Generating"') }]
		},
		Notification: {
			hooks: [{ type: 'command', command: makeHookCommand('"waiting"', 'j.notification_type') }]
		},
		Stop: {
			hooks: [{ type: 'command', command: makeHookCommand('"completed"', '"Done"') }]
		},
		SessionStart: {
			hooks: [{ type: 'command', command: makeHookCommand('"session_start"', 'j.source') }]
		},
		SessionEnd: {
			hooks: [{ type: 'command', command: makeHookCommand('"session_end"', 'j.reason') }]
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
