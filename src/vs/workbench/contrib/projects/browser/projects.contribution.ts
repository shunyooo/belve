/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { SyncDescriptor } from '../../../../platform/instantiation/common/descriptors.js';
import { InstantiationType, registerSingleton } from '../../../../platform/instantiation/common/extensions.js';
import { Registry } from '../../../../platform/registry/common/platform.js';
import { Codicon } from '../../../../base/common/codicons.js';
import { registerIcon } from '../../../../platform/theme/common/iconRegistry.js';
import { localize, localize2 } from '../../../../nls.js';
import { ViewPaneContainer } from '../../../browser/parts/views/viewPaneContainer.js';
import { Extensions as ViewContainerExtensions, IViewContainersRegistry, IViewDescriptor, IViewsRegistry, ViewContainer, ViewContainerLocation } from '../../../common/views.js';
import { IProjectService, PROJECTS_VIEW_CONTAINER_ID, PROJECTS_VIEW_ID } from '../common/project.js';
import { ProjectService } from './projectService.js';
import { ProjectsView } from './views/projectsView.js';
import './projectsActions.js';

const projectsViewIcon = registerIcon('dock-projects-icon', Codicon.project, localize('projectsViewIcon', 'Icon for Projects View'));
const PROJECTS_VIEW_TITLE = localize2('dockcode.projects.view.label', "Projects");

const projectsViewContainer: ViewContainer = Registry.as<IViewContainersRegistry>(ViewContainerExtensions.ViewContainersRegistry).registerViewContainer({
	id: PROJECTS_VIEW_CONTAINER_ID,
	title: PROJECTS_VIEW_TITLE,
	icon: projectsViewIcon,
	ctorDescriptor: new SyncDescriptor(ViewPaneContainer, [PROJECTS_VIEW_CONTAINER_ID, { mergeViewWithContainerWhenSingleView: true }]),
	storageId: PROJECTS_VIEW_CONTAINER_ID,
	hideIfEmpty: false,
	order: 0,
}, ViewContainerLocation.Sidebar);

const projectsViewPaneDescriptor: IViewDescriptor = {
	id: PROJECTS_VIEW_ID,
	containerIcon: projectsViewIcon,
	containerTitle: PROJECTS_VIEW_TITLE.value,
	singleViewPaneContainerTitle: PROJECTS_VIEW_TITLE.value,
	name: PROJECTS_VIEW_TITLE,
	canToggleVisibility: false,
	canMoveView: false,
	ctorDescriptor: new SyncDescriptor(ProjectsView),
};

Registry.as<IViewsRegistry>(ViewContainerExtensions.ViewsRegistry).registerViews([projectsViewPaneDescriptor], projectsViewContainer);

registerSingleton(IProjectService, ProjectService, InstantiationType.Delayed);
