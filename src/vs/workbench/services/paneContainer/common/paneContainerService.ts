/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

/**
 * Direction enum for pane navigation/splitting.
 * Defined here in the common layer to avoid importing from browser.
 * Values match the Direction enum in base/browser/ui/grid/grid.js.
 */
export const enum PaneDirection {
	Up = 0,
	Down = 1,
	Left = 2,
	Right = 3,
}

export interface IPaneContainerService {
	focus(): void;
	/** Returns true if moved within PaneContainer, false if at edge */
	focusPaneInDirection(direction: PaneDirection): boolean;
	splitActivePane(direction: PaneDirection): void;
	closeActivePane(): void;
	togglePaneZoom(): void;
	focusNextPane(): void;
	focusPreviousPane(): void;
	getPaneCount(): number;
	getActivePaneIndex(): number;
	focusPaneAtIndex(index: number): void;
}

/**
 * Global reference to the PaneContainerPart instance.
 * Set during initialization in paneCompositePartService.ts.
 */
let _instance: IPaneContainerService | undefined;

export function setPaneContainerInstance(instance: IPaneContainerService): void {
	_instance = instance;
}

export function getPaneContainerInstance(): IPaneContainerService | undefined {
	return _instance;
}
