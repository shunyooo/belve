/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import { IMainProcessService } from '../../../../platform/ipc/common/mainProcessService.js';
import { InstantiationType, registerSingleton } from '../../../../platform/instantiation/common/extensions.js';
import { IProjectMainService } from '../../../../platform/projects/common/projects.js';
import { ProjectMainServiceClient } from '../../../../platform/projects/common/projectIpcClient.js';

export class NativeProjectMainService extends ProjectMainServiceClient {

	constructor(
		@IMainProcessService mainProcessService: IMainProcessService,
	) {
		super(mainProcessService.getChannel('projects'));
	}
}

registerSingleton(IProjectMainService, NativeProjectMainService, InstantiationType.Delayed);
