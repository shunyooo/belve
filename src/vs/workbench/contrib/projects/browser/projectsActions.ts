/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { localize2 } from '../../../../nls.js';
import { Action2, registerAction2 } from '../../../../platform/actions/common/actions.js';
import { ServicesAccessor } from '../../../../platform/instantiation/common/instantiation.js';
import { IQuickInputService } from '../../../../platform/quickinput/common/quickInput.js';
import { IProjectService } from '../common/project.js';
import { localize } from '../../../../nls.js';

class NewProjectAction extends Action2 {
	constructor() {
		super({
			id: 'dockcode.projects.new',
			title: localize2('newProject', "New Project"),
			f1: true,
		});
	}

	override async run(accessor: ServicesAccessor): Promise<void> {
		const projectService = accessor.get(IProjectService);
		const quickInputService = accessor.get(IQuickInputService);
		const name = await quickInputService.input({
			placeHolder: localize('projectNamePlaceholder', "Project name"),
			prompt: localize('projectNamePrompt', "Enter a name for the new project"),
		});
		if (name) {
			const project = projectService.createProject(name);
			projectService.setActiveProject(project.id);
		}
	}
}

registerAction2(NewProjectAction);
