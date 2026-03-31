/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { InstantiationType, registerSingleton } from '../../../../platform/instantiation/common/extensions.js';
import { IProjectService } from '../common/project.js';
import { ProjectService } from './projectService.js';
import './projectsActions.js';

// Legacy renderer-only project service — will be replaced by IProjectMainService
registerSingleton(IProjectService, ProjectService, InstantiationType.Delayed);
