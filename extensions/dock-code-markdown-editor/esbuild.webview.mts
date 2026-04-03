/*---------------------------------------------------------------------------------------------
 *  Copyright (c) dock-code contributors. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/
import path from 'path';
import { run } from '../esbuild-webview-common.mts';

const srcDir = path.join(import.meta.dirname, 'webview-src');
const outDir = path.join(import.meta.dirname, 'media');

run({
	entryPoints: [
		path.join(srcDir, 'index.ts'),
	],
	srcDir,
	outdir: outDir,
	additionalOptions: {
		loader: {
			'.woff': 'dataurl',
			'.woff2': 'dataurl',
			'.ttf': 'dataurl',
		},
	},
}, process.argv);
