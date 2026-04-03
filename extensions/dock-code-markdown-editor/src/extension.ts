/*---------------------------------------------------------------------------------------------
 *  Copyright (c) dock-code contributors. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/
import * as vscode from 'vscode';
import { MarkdownEditorProvider } from './markdownEditorProvider';

export function activate(context: vscode.ExtensionContext) {
	console.warn('[dock-code-markdown-editor] activating...');
	context.subscriptions.push(
		MarkdownEditorProvider.register(context)
	);
	console.warn('[dock-code-markdown-editor] activated');
}
