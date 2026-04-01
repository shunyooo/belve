/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

/* eslint-disable no-restricted-syntax, local/code-translation-remind */

import { localize2 } from '../../../../nls.js';
import { Action2, registerAction2 } from '../../../../platform/actions/common/actions.js';
import { ServicesAccessor } from '../../../../platform/instantiation/common/instantiation.js';
import { KeyCode, KeyMod, KeyChord } from '../../../../base/common/keyCodes.js';
import { KeybindingWeight } from '../../../../platform/keybinding/common/keybindingsRegistry.js';
import { PaneDirection, getPaneContainerInstance } from '../../../services/paneContainer/common/paneContainerService.js';
import { showFocusGlow } from '../../../browser/parts/paneContainer/paneView.js';
import { IProjectMainService } from '../../../../platform/projects/common/projects.js';
import { IQuickInputService, IQuickPickItem } from '../../../../platform/quickinput/common/quickInput.js';
import { IWorkbenchLayoutService } from '../../../services/layout/browser/layoutService.js';
import { mainWindow } from '../../../../base/browser/window.js';
import { getActiveElement, isHTMLElement } from '../../../../base/browser/dom.js';

// ============================================================================
// Keybinding Configuration
//
// All dock-code keybindings are defined here as data.
// Prefix key: Ctrl+B (same on all platforms, like tmux)
//
// To customize, users can override in VS Code's keybindings.json using
// the command IDs (e.g. "dockcode.pane.focusUp").
// ============================================================================

const PREFIX = KeyMod.WinCtrl | KeyCode.KeyA;

const keybindings = {
	// Pane navigation
	'dockcode.pane.focusUp': KeyChord(PREFIX, KeyCode.UpArrow),
	'dockcode.pane.focusDown': KeyChord(PREFIX, KeyCode.DownArrow),
	'dockcode.pane.focusLeft': KeyChord(PREFIX, KeyCode.LeftArrow),
	'dockcode.pane.focusRight': KeyChord(PREFIX, KeyCode.RightArrow),

	// Pane split / close / zoom
	'dockcode.pane.splitDown': KeyChord(PREFIX, KeyMod.Shift | KeyCode.Quote),   // Ctrl+B, "
	'dockcode.pane.splitRight': KeyChord(PREFIX, KeyMod.Shift | KeyCode.Digit5),  // Ctrl+B, %
	'dockcode.pane.close': KeyChord(PREFIX, KeyCode.KeyX),                   // Ctrl+B, x
	'dockcode.pane.toggleZoom': KeyChord(PREFIX, KeyCode.KeyZ),                   // Ctrl+B, z

	// Project switching
	'dockcode.project.next': KeyChord(PREFIX, KeyCode.KeyN),
	'dockcode.project.previous': KeyChord(PREFIX, KeyCode.KeyP),
	'dockcode.project.quickPick': KeyChord(PREFIX, KeyCode.KeyW),
	'dockcode.project.switchTo1': KeyChord(PREFIX, KeyCode.Digit1),
	'dockcode.project.switchTo2': KeyChord(PREFIX, KeyCode.Digit2),
	'dockcode.project.switchTo3': KeyChord(PREFIX, KeyCode.Digit3),
	'dockcode.project.switchTo4': KeyChord(PREFIX, KeyCode.Digit4),
	'dockcode.project.switchTo5': KeyChord(PREFIX, KeyCode.Digit5),
	'dockcode.project.switchTo6': KeyChord(PREFIX, KeyCode.Digit6),
	'dockcode.project.switchTo7': KeyChord(PREFIX, KeyCode.Digit7),
	'dockcode.project.switchTo8': KeyChord(PREFIX, KeyCode.Digit8),
	'dockcode.project.switchTo9': KeyChord(PREFIX, KeyCode.Digit9),

	// Focus cycling
	'dockcode.focus.cycle': KeyChord(PREFIX, KeyCode.Tab),

	// Quick pane cycling (single-stroke, no prefix)
	'dockcode.pane.focusPrev': KeyMod.Alt | KeyCode.Semicolon,      // Option+;
	'dockcode.pane.focusNext': KeyMod.Alt | KeyCode.Quote,         // Option+'

	// Quick project switching (Cmd+1-9, single-stroke)
	'dockcode.project.quick1': KeyMod.CtrlCmd | KeyCode.Digit1,
	'dockcode.project.quick2': KeyMod.CtrlCmd | KeyCode.Digit2,
	'dockcode.project.quick3': KeyMod.CtrlCmd | KeyCode.Digit3,
	'dockcode.project.quick4': KeyMod.CtrlCmd | KeyCode.Digit4,
	'dockcode.project.quick5': KeyMod.CtrlCmd | KeyCode.Digit5,
	'dockcode.project.quick6': KeyMod.CtrlCmd | KeyCode.Digit6,
	'dockcode.project.quick7': KeyMod.CtrlCmd | KeyCode.Digit7,
	'dockcode.project.quick8': KeyMod.CtrlCmd | KeyCode.Digit8,
	'dockcode.project.quick9': KeyMod.CtrlCmd | KeyCode.Digit9,
} as const;

// ============================================================================
// Command Definitions
// ============================================================================

const DOCK_CODE_CATEGORY = localize2('dockCodeCategory', "dock-code");

function kb(id: keyof typeof keybindings) {
	// These shortcuts need higher weight to override VS Code defaults
	const isHighPriority =
		id === 'dockcode.pane.focusPrev' ||
		id === 'dockcode.pane.focusNext' ||
		id.startsWith('dockcode.project.quick');
	return {
		weight: isHighPriority
			? KeybindingWeight.WorkbenchContrib + 50
			: KeybindingWeight.WorkbenchContrib,
		primary: keybindings[id],
	};
}

// --- Directional Navigation ---
//
// Smart navigation: moves within PaneContainer panes first,
// then crosses boundary to/from VS Code workbench at edges.
//
// Layout:  [ PaneContainer (left) | Workbench (right) ]
//   - Right at PaneContainer edge → focus Workbench
//   - Left in Workbench           → focus PaneContainer

function navigateInDirection(direction: PaneDirection, accessor: ServicesAccessor): void {
	const paneContainer = getPaneContainerInstance();
	const layoutService = accessor.get(IWorkbenchLayoutService);

	const paneContainerEl = mainWindow.document.querySelector('.pane-container-part');
	const isInPaneContainer = paneContainerEl?.contains(getActiveElement());

	if (isInPaneContainer) {
		// Try moving within PaneContainer first
		const moved = paneContainer?.focusPaneInDirection(direction);
		if (!moved && direction === PaneDirection.Right) {
			// At right edge → cross to Workbench
			layoutService.focus();
			// Glow the editor area
			const editorPart = mainWindow.document.querySelector('.part.editor');
			if (editorPart && isHTMLElement(editorPart)) {
				showFocusGlow(editorPart);
			}
		}
	} else {
		if (direction === PaneDirection.Left) {
			// In Workbench → cross to PaneContainer
			paneContainer?.focus();
			// PaneView handles its own glow via onDidFocus
		}
	}
}

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusUp', title: localize2('focusPaneUp', "Focus Pane Above"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusUp') });
	}
	run(accessor: ServicesAccessor) { navigateInDirection(PaneDirection.Up, accessor); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusDown', title: localize2('focusPaneDown', "Focus Pane Below"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusDown') });
	}
	run(accessor: ServicesAccessor) { navigateInDirection(PaneDirection.Down, accessor); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusLeft', title: localize2('focusPaneLeft', "Focus Pane to the Left"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusLeft') });
	}
	run(accessor: ServicesAccessor) { navigateInDirection(PaneDirection.Left, accessor); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusRight', title: localize2('focusPaneRight', "Focus Pane to the Right"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusRight') });
	}
	run(accessor: ServicesAccessor) { navigateInDirection(PaneDirection.Right, accessor); }
});

// --- Quick Area Cycling (Option+; / Option+') ---
//
// Cycles through all focusable areas: PaneContainer panes + Workbench editor
// Order: [Pane0, Pane1, ..., PaneN, Editor]

function getAreaCount(): number {
	const paneContainer = getPaneContainerInstance();
	const paneCount = paneContainer?.getPaneCount() ?? 0;
	return paneCount + 1; // +1 for editor
}

function getCurrentAreaIndex(): number {
	const paneContainer = getPaneContainerInstance();
	const paneContainerEl = mainWindow.document.querySelector('.pane-container-part');
	if (paneContainerEl?.contains(getActiveElement())) {
		return paneContainer?.getActivePaneIndex() ?? 0;
	}
	// In workbench → last index
	return (paneContainer?.getPaneCount() ?? 0);
}

function focusAreaAtIndex(index: number, accessor: ServicesAccessor): void {
	const paneContainer = getPaneContainerInstance();
	const layoutService = accessor.get(IWorkbenchLayoutService);
	const paneCount = paneContainer?.getPaneCount() ?? 0;

	if (index < paneCount) {
		// Blur the current active element first (needed for webview-based editors
		// like Welcome tab that aggressively hold focus)
		const active = getActiveElement();
		if (isHTMLElement(active)) {
			active.blur();
		}
		// Use requestAnimationFrame to ensure focus happens after any pending
		// editor focus restoration from the layout service
		mainWindow.requestAnimationFrame(() => {
			paneContainer?.focusPaneAtIndex(index);
		});
	} else {
		// Editor
		layoutService.focus();
		const editorPart = mainWindow.document.querySelector('.part.editor');
		if (editorPart && isHTMLElement(editorPart)) { showFocusGlow(editorPart); }
	}
}

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusPrev', title: localize2('focusPanePrev', "Focus Previous Area"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusPrev') });
	}
	run(accessor: ServicesAccessor) {
		const total = getAreaCount();
		const cur = getCurrentAreaIndex();
		focusAreaAtIndex((cur - 1 + total) % total, accessor);
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.focusNext', title: localize2('focusPaneNext', "Focus Next Area"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.focusNext') });
	}
	run(accessor: ServicesAccessor) {
		const total = getAreaCount();
		const cur = getCurrentAreaIndex();
		focusAreaAtIndex((cur + 1) % total, accessor);
	}
});

// --- Pane Split / Close / Zoom ---

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.splitDown', title: localize2('splitPaneDown', "Split Pane Down"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.splitDown') });
	}
	run() { getPaneContainerInstance()?.splitActivePane(PaneDirection.Down); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.splitRight', title: localize2('splitPaneRight', "Split Pane Right"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.splitRight') });
	}
	run() { getPaneContainerInstance()?.splitActivePane(PaneDirection.Right); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.close', title: localize2('closePane', "Close Active Pane"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.close') });
	}
	run() { getPaneContainerInstance()?.closeActivePane(); }
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.pane.toggleZoom', title: localize2('togglePaneZoom', "Toggle Pane Zoom"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.pane.toggleZoom') });
	}
	run() { getPaneContainerInstance()?.togglePaneZoom(); }
});

// --- Project Switching ---

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.project.next', title: localize2('nextProject', "Switch to Next Project"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.project.next') });
	}
	async run(accessor: ServicesAccessor) {
		const projectService = accessor.get(IProjectMainService);
		const projects = await projectService.getProjects();
		const active = await projectService.getActiveProject();
		if (projects.length <= 1 || !active) { return; }
		const idx = projects.findIndex(p => p.id === active.id);
		await projectService.switchToProject(projects[(idx + 1) % projects.length].id);
	}
});

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.project.previous', title: localize2('prevProject', "Switch to Previous Project"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.project.previous') });
	}
	async run(accessor: ServicesAccessor) {
		const projectService = accessor.get(IProjectMainService);
		const projects = await projectService.getProjects();
		const active = await projectService.getActiveProject();
		if (projects.length <= 1 || !active) { return; }
		const idx = projects.findIndex(p => p.id === active.id);
		await projectService.switchToProject(projects[(idx - 1 + projects.length) % projects.length].id);
	}
});

for (let i = 1; i <= 9; i++) {
	const id = `dockcode.project.switchTo${i}` as keyof typeof keybindings;
	registerAction2(class extends Action2 {
		constructor() {
			super({ id, title: localize2(`switchToProject${i}`, "Switch to Project {0}", i), category: DOCK_CODE_CATEGORY, keybinding: kb(id) });
		}
		async run(accessor: ServicesAccessor) {
			const projectService = accessor.get(IProjectMainService);
			const projects = await projectService.getProjects();
			if (projects[i - 1]) { await projectService.switchToProject(projects[i - 1].id); }
		}
	});
}

// Cmd+1-9: Quick project switching (single-stroke, overrides VS Code's "open Nth editor")
for (let i = 1; i <= 9; i++) {
	const id = `dockcode.project.quick${i}` as keyof typeof keybindings;
	registerAction2(class extends Action2 {
		constructor() {
			super({ id, title: localize2(`quickSwitchProject${i}`, "Quick Switch to Project {0}", i), category: DOCK_CODE_CATEGORY, keybinding: kb(id) });
		}
		async run(accessor: ServicesAccessor) {
			const projectService = accessor.get(IProjectMainService);
			const projects = await projectService.getProjects();
			if (projects[i - 1]) { await projectService.switchToProject(projects[i - 1].id); }
		}
	});
}

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.project.quickPick', title: localize2('projectQuickPick', "Quick Switch Project"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.project.quickPick') });
	}
	async run(accessor: ServicesAccessor) {
		const projectService = accessor.get(IProjectMainService);
		const quickInputService = accessor.get(IQuickInputService);
		const projects = await projectService.getProjects();
		const active = await projectService.getActiveProject();
		const items: IQuickPickItem[] = projects.map((p, idx) => ({
			label: `${idx + 1}: ${p.name}`,
			description: p.id === active?.id ? '(active)' : '',
			id: p.id,
		}));
		const picked = await quickInputService.pick(items, { placeHolder: 'Switch to project...' });
		if (picked?.id) { await projectService.switchToProject(picked.id); }
	}
});

// --- Focus Cycling ---

registerAction2(class extends Action2 {
	constructor() {
		super({ id: 'dockcode.focus.cycle', title: localize2('cycleFocus', "Cycle Focus Between Pane and Workbench"), category: DOCK_CODE_CATEGORY, f1: true, keybinding: kb('dockcode.focus.cycle') });
	}
	run(accessor: ServicesAccessor) {
		const layoutService = accessor.get(IWorkbenchLayoutService);
		const paneContainer = getPaneContainerInstance();
		const paneContainerEl = mainWindow.document.querySelector('.pane-container-part');
		if (paneContainerEl?.contains(getActiveElement())) {
			layoutService.focus();
			const editorPart = mainWindow.document.querySelector('.part.editor');
			if (editorPart && isHTMLElement(editorPart)) { showFocusGlow(editorPart); }
		} else {
			paneContainer?.focus();
			// PaneView handles its own glow via onDidFocus
		}
	}
});
