/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

import * as vscode from 'vscode';
import * as cp from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import * as crypto from 'crypto';
import * as net from 'net';

let outputChannel: vscode.OutputChannel;

/** Active processes per authority, for cleanup */
const activeProcesses = new Map<string, cp.ChildProcess[]>();

/** Cached resolved connections per authority (reused on workspace folder redirect) */
interface CachedConnection {
	localPort: number;
	connectionToken: string;
	remoteWorkspaceFolder: string;
}
const resolvedConnections = new Map<string, CachedConnection>();

export function activate(context: vscode.ExtensionContext) {
	outputChannel = vscode.window.createOutputChannel('Remote - Containers');

	const resolverDisposable = vscode.workspace.registerRemoteAuthorityResolver('dev-container', {
		async getCanonicalURI(uri: vscode.Uri): Promise<vscode.Uri> {
			return vscode.Uri.file(uri.path);
		},
		resolve(authority: string): Thenable<vscode.ResolverResult> {
			return vscode.window.withProgress({
				location: vscode.ProgressLocation.Notification,
				title: 'Opening Dev Container ([show log](command:dock-code-remote-containers.showLog))',
				cancellable: false
			}, (progress) => doResolve(authority, progress, context));
		}
	});
	context.subscriptions.push(resolverDisposable);

	// Command: Open Folder in Container on SSH Host
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.openInContainer', async () => {
		// Step 1: Pick SSH host
		const hosts = parseSSHConfigHosts();
		const hostItems: vscode.QuickPickItem[] = hosts.map(h => ({ label: h }));
		hostItems.push({ label: '$(plus) Enter host manually...', description: 'user@hostname' });

		const selectedHost = await vscode.window.showQuickPick(hostItems, {
			placeHolder: 'Select SSH host where containers run',
			title: 'Dev Containers: Select SSH Host'
		});
		if (!selectedHost) {
			return;
		}

		let host: string;
		if (selectedHost.label.includes('Enter host manually')) {
			const input = await vscode.window.showInputBox({
				prompt: 'Enter SSH host (e.g., user@hostname)',
				placeHolder: 'user@hostname'
			});
			if (!input) {
				return;
			}
			host = input;
		} else {
			host = selectedHost.label;
		}

		// Step 2: Browse remote folders
		const folderPath = await browseRemoteFolders(host);
		if (!folderPath) {
			return;
		}

		// Encode as: host:folderPath in hex
		const authorityId = Buffer.from(`${host}:${folderPath}`).toString('hex');
		await vscode.commands.executeCommand('vscode.newWindow', {
			remoteAuthority: `dev-container+${authorityId}`,
			reuseWindow: true
		});
	}));

	// Command: Rebuild Container
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.rebuildContainer', async () => {
		await vscode.commands.executeCommand('workbench.action.reloadWindow');
	}));

	// Command: Show Log
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.showLog', () => {
		outputChannel.show();
	}));

	context.subscriptions.push({
		dispose: () => {
			for (const [, procs] of activeProcesses) {
				procs.forEach(p => p.kill());
			}
			activeProcesses.clear();
		}
	});

	// Command: Reopen without Container (DevContainer → SSH)
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.reopenWithoutContainer', async () => {
		// Currently in a dev-container, switch back to SSH
		if (vscode.env.remoteName !== 'dev-container') {
			return;
		}
		const folders = vscode.workspace.workspaceFolders;
		if (!folders || folders.length === 0) {
			return;
		}
		// The authority encodes host:folderPath — extract the SSH host
		const folder = folders[0];
		const authority = folder.uri.authority;
		const hexPayload = authority.substring(authority.indexOf('+') + 1);
		const payload = Buffer.from(hexPayload, 'hex').toString('utf8');
		const colonIdx = payload.indexOf(':');
		const host = payload.substring(0, colonIdx);
		const folderPath = payload.substring(colonIdx + 1);

		// Switch to SSH remote with the same folder
		const sshUri = vscode.Uri.parse(`vscode-remote://ssh-remote+${host}${folderPath}`);
		await vscode.commands.executeCommand('vscode.openFolder', sshUri, { forceReuseWindow: true });
	}));

	// Auto-detect devcontainer.json in current workspace (local or SSH)
	detectDevcontainerInWorkspace();
}

/**
 * Browse remote directories via SSH and let the user pick a folder.
 * Shows directories with devcontainer.json highlighted.
 */
async function browseRemoteFolders(host: string): Promise<string | undefined> {
	let currentPath = '~';

	// Resolve ~ to absolute path
	try {
		currentPath = (await sshExec(host, 'echo $HOME')).trim();
	} catch {
		currentPath = '/home';
	}

	while (true) {
		// List directories and check for devcontainer.json
		let listing: string;
		try {
			listing = await sshExec(host,
				`cd "${currentPath}" && for d in */ .; do ` +
				`if [ -d "$d" ] && [ "$d" != "./" ]; then ` +
				`  if [ -f "$d/.devcontainer/devcontainer.json" ] || [ -f "$d/.devcontainer.json" ]; then ` +
				`    echo "DEVCONTAINER:$d"; ` +
				`  else echo "DIR:$d"; fi; ` +
				`fi; done 2>/dev/null`
			);
		} catch {
			listing = '';
		}

		const items: vscode.QuickPickItem[] = [];

		// Parent directory
		items.push({
			label: '$(arrow-up) ..',
			description: path.dirname(currentPath),
			alwaysShow: true
		});

		// Current directory (select this)
		items.push({
			label: '$(check) Open this folder',
			description: currentPath,
			alwaysShow: true
		});

		// Subdirectories
		const lines = listing.trim().split('\n').filter(l => l.length > 0);
		for (const line of lines) {
			const isDevcontainer = line.startsWith('DEVCONTAINER:');
			const dirName = line.replace(/^(DEVCONTAINER|DIR):/, '').replace(/\/$/, '');
			if (!dirName || dirName === '.' || dirName === '..') {
				continue;
			}
			items.push({
				label: isDevcontainer ? `$(container) ${dirName}` : `$(folder) ${dirName}`,
				description: isDevcontainer ? 'devcontainer.json' : '',
			});
		}

		const selected = await vscode.window.showQuickPick(items, {
			placeHolder: currentPath,
			title: `Browse: ${currentPath}`
		});

		if (!selected) {
			return undefined;
		}

		if (selected.label.includes('Open this folder')) {
			return currentPath;
		} else if (selected.label.includes('..')) {
			currentPath = path.dirname(currentPath);
		} else {
			// Extract folder name (remove icon prefix)
			const folderName = selected.label.replace(/^\$\([^)]+\)\s*/, '');
			currentPath = currentPath === '/' ? `/${folderName}` : `${currentPath}/${folderName}`;
		}
	}
}

/**
 * Detect devcontainer.json in current workspace and offer to reopen in container.
 * Works for both local and SSH-connected workspaces.
 */
async function detectDevcontainerInWorkspace(): Promise<void> {
	// Skip if already in a dev container
	if (vscode.env.remoteName === 'dev-container') {
		return;
	}

	const folders = vscode.workspace.workspaceFolders;
	if (!folders || folders.length === 0) {
		return;
	}

	for (const folder of folders) {
		const candidates = [
			vscode.Uri.joinPath(folder.uri, '.devcontainer', 'devcontainer.json'),
			vscode.Uri.joinPath(folder.uri, '.devcontainer.json'),
		];

		for (const candidate of candidates) {
			try {
				await vscode.workspace.fs.stat(candidate);

				// Found devcontainer.json
				if (vscode.env.remoteName === 'ssh-remote') {
					// SSH connected — offer to reopen in container
					const host = folder.uri.authority.replace(/^ssh-remote\+/, '');
					const folderPath = folder.uri.path;

					const result = await vscode.window.showInformationMessage(
						`This folder has a Dev Container configuration. Reopen in container?`,
						'Reopen in Container',
						'Not Now'
					);
					if (result === 'Reopen in Container') {
						const authorityId = Buffer.from(`${host}:${folderPath}`).toString('hex');
						await vscode.commands.executeCommand('vscode.newWindow', {
							remoteAuthority: `dev-container+${authorityId}`,
							reuseWindow: true
						});
					}
				} else {
					// Local — offer to open in container (needs SSH host selection)
					const result = await vscode.window.showInformationMessage(
						`Folder "${folder.name}" has a Dev Container configuration. Open in container on remote host?`,
						'Open in Container',
						'Not Now'
					);
					if (result === 'Open in Container') {
						await vscode.commands.executeCommand('dock-code-remote-containers.openInContainer');
					}
				}
				return; // Only show once
			} catch {
				// File doesn't exist, continue
			}
		}
	}
}

/**
 * Parse SSH config to get host names.
 */
function parseSSHConfigHosts(): string[] {
	const configPath = path.join(os.homedir(), '.ssh', 'config');
	if (!fs.existsSync(configPath)) {
		return [];
	}
	const content = fs.readFileSync(configPath, 'utf8');
	const hosts: string[] = [];
	for (const line of content.split('\n')) {
		const match = line.match(/^\s*Host\s+(.+)/i);
		if (match) {
			for (const pattern of match[1].trim().split(/\s+/)) {
				if (!pattern.includes('*') && !pattern.includes('?')) {
					hosts.push(pattern);
				}
			}
		}
	}
	return hosts;
}

/**
 * Execute a command on the remote via SSH.
 */
function sshExec(host: string, command: string): Promise<string> {
	return new Promise((resolve, reject) => {
		const proc = cp.spawn('ssh', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ConnectTimeout=15',
			host, command
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let stdout = '';
		let stderr = '';
		proc.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
		proc.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });

		proc.on('close', (code) => {
			if (code === 0) {
				resolve(stdout);
			} else {
				reject(new Error(`SSH command failed (code ${code}): ${stderr.substring(0, 500)}`));
			}
		});
		proc.on('error', (err) => reject(new Error(`SSH failed: ${err.message}`)));
	});
}

/**
 * Get product configuration.
 */
function getProductConfig(): { commit?: string; serverApplicationName: string; serverDataFolderName: string } {
	const productPath = path.join(vscode.env.appRoot, 'product.json');
	const content = JSON.parse(fs.readFileSync(productPath, 'utf8'));
	return {
		commit: content.commit,
		serverApplicationName: content.serverApplicationName || 'dock-code-server',
		serverDataFolderName: content.serverDataFolderName || '.dock-code-server',
	};
}

/**
 * Schedule opening the correct workspace folder after resolver returns.
 * Needed because the initial connection may open to /root (container default),
 * and on cached reconnections the folder check was previously skipped.
 */
function scheduleWorkspaceFolderOpen(authority: string, remoteWorkspaceFolder: string): void {
	setTimeout(() => {
		const folders = vscode.workspace.workspaceFolders;
		const currentPath = folders?.[0]?.uri.path;
		if (currentPath !== remoteWorkspaceFolder) {
			outputChannel.appendLine(`  Opening workspace folder: ${remoteWorkspaceFolder}`);
			const uri = vscode.Uri.from({
				scheme: 'vscode-remote',
				authority,
				path: remoteWorkspaceFolder,
			});
			vscode.commands.executeCommand('vscode.openFolder', uri, { forceReuseWindow: true });
		}
	}, 0);
}

/**
 * Main resolve function.
 * Authority format: dev-container+<hex(host:folderPath)>
 */
async function doResolve(
	authority: string,
	progress: vscode.Progress<{ message?: string }>,
	context: vscode.ExtensionContext
): Promise<vscode.ResolverResult> {
	const hexPayload = authority.substring(authority.indexOf('+') + 1);
	const payload = Buffer.from(hexPayload, 'hex').toString('utf8');
	const colonIdx = payload.indexOf(':');
	const host = payload.substring(0, colonIdx);
	const folderPath = payload.substring(colonIdx + 1);

	outputChannel.appendLine(`[${new Date().toISOString()}] Resolving Dev Container`);
	outputChannel.appendLine(`  SSH host: ${host}`);
	outputChannel.appendLine(`  Folder: ${folderPath}`);

	// Reuse cached connection (e.g. after workspace folder redirect)
	const cached = resolvedConnections.get(authority);
	if (cached) {
		outputChannel.appendLine('  Reusing cached connection');
		// Ensure correct workspace folder is open (may have been /root on first connect)
		const fullAuthority = `dev-container+${hexPayload}`;
		scheduleWorkspaceFolderOpen(fullAuthority, cached.remoteWorkspaceFolder);
		return new vscode.ResolvedAuthority('127.0.0.1', cached.localPort, cached.connectionToken);
	}

	const connectionToken = crypto.randomBytes(20).toString('hex');
	const product = getProductConfig();
	const commit = product.commit || await getLocalCommit(context);

	// Step 1: Test SSH connection
	progress.report({ message: 'Connecting to SSH host...' });
	try {
		await sshExec(host, 'echo ok');
	} catch (err: any) {
		throw vscode.RemoteAuthorityResolverError.NotAvailable(
			`Could not connect to "${host}": ${err.message}`, true
		);
	}

	// Step 2: Check devcontainer CLI on remote
	progress.report({ message: 'Checking devcontainer CLI...' });
	try {
		const version = await sshExec(host, 'devcontainer --version');
		outputChannel.appendLine(`  devcontainer CLI version: ${version.trim()}`);
	} catch {
		outputChannel.appendLine('  devcontainer CLI not found, installing...');
		try {
			await sshExec(host, 'npm install -g @devcontainers/cli');
		} catch (err: any) {
			throw vscode.RemoteAuthorityResolverError.NotAvailable(
				`Failed to install devcontainer CLI on ${host}: ${err.message}`, true
			);
		}
	}

	// Step 3: Start/build the dev container on remote
	progress.report({ message: 'Starting Dev Container...' });
	const { containerId, remoteWorkspaceFolder } = await startRemoteDevContainer(host, folderPath);
	outputChannel.appendLine(`  Container ID: ${containerId}`);

	// Step 4: Install REH server in container (via SSH → docker exec)
	// Download from GitHub Release directly into the container
	progress.report({ message: 'Installing dock-code server in container...' });
	const serverInstallDir = `/home/${product.serverDataFolderName}/bin/${commit}`;
	const serverBinPath = `${serverInstallDir}/bin/${product.serverApplicationName}`;

	const serverExists = await checkRemoteContainerFile(host, containerId, serverBinPath);
	if (!serverExists) {
		await installServerInRemoteContainer(host, containerId, commit, product, context, progress);
	} else {
		outputChannel.appendLine('  Server already installed in container');
	}

	// Step 5: Start REH server in container
	progress.report({ message: 'Starting remote server...' });
	const { port: containerPort, process: serverProcess } = await startServerInRemoteContainer(
		host, containerId, serverBinPath, connectionToken
	);

	// Step 6: Set up SSH tunnel to container port
	progress.report({ message: 'Setting up tunnel...' });
	const remoteHostPort = await getRemoteContainerPortMapping(host, containerId, containerPort);
	const localPort = await findFreePort();
	const tunnelProcess = await createSSHTunnel(host, localPort, remoteHostPort);

	// Track processes for cleanup
	const procs = [serverProcess, tunnelProcess];
	activeProcesses.set(authority, procs);
	context.subscriptions.push({
		dispose: () => {
			procs.forEach(p => p.kill());
			activeProcesses.delete(authority);
			resolvedConnections.delete(authority);
		}
	});

	outputChannel.appendLine(`  Tunnel: localhost:${localPort} → ${host}:${remoteHostPort} → container:${containerPort}`);
	outputChannel.appendLine(`  Workspace folder: ${remoteWorkspaceFolder}`);

	// Cache the connection for reuse on workspace folder redirect
	resolvedConnections.set(authority, { localPort, connectionToken, remoteWorkspaceFolder });

	// Open the container's workspace folder if not already open
	// Schedule after resolve returns to avoid blocking the resolver
	const fullAuthority = `dev-container+${hexPayload}`;
	scheduleWorkspaceFolderOpen(fullAuthority, remoteWorkspaceFolder);

	return new vscode.ResolvedAuthority('127.0.0.1', localPort, connectionToken);
}

/**
 * Start a dev container on the remote host.
 */
async function startRemoteDevContainer(host: string, folderPath: string): Promise<{ containerId: string; remoteWorkspaceFolder: string }> {
	outputChannel.appendLine(`  Running devcontainer up on ${host}...`);
	const output = await sshExec(host, `devcontainer up --workspace-folder "${folderPath}" 2>&1`);

	// Parse JSON output (last line)
	const lines = output.trim().split('\n');
	for (let i = lines.length - 1; i >= 0; i--) {
		try {
			const result = JSON.parse(lines[i]);
			if (result.containerId) {
				const remoteWorkspaceFolder = result.remoteWorkspaceFolder || '/workspaces/' + path.basename(folderPath);
				outputChannel.appendLine(`  Remote workspace folder: ${remoteWorkspaceFolder}`);
				return { containerId: result.containerId, remoteWorkspaceFolder };
			}
		} catch {
			continue;
		}
	}

	throw new Error(`devcontainer up did not return containerId. Output:\n${output.substring(0, 500)}`);
}

/**
 * Check if a file exists in a container on the remote host.
 */
async function checkRemoteContainerFile(host: string, containerId: string, filePath: string): Promise<boolean> {
	try {
		await sshExec(host, `docker exec ${containerId} test -f ${filePath}`);
		return true;
	} catch {
		return false;
	}
}

/** GitHub repository for downloading REH releases */
const REH_GITHUB_REPO = 'shunyooo/dock-code';

/**
 * Install REH server in a container on the remote host.
 * Downloads from GitHub Release directly into the container.
 */
async function installServerInRemoteContainer(
	host: string,
	containerId: string,
	commit: string,
	product: { serverDataFolderName: string; serverApplicationName: string },
	_context: vscode.ExtensionContext,
	progress: vscode.Progress<{ message?: string }>
): Promise<void> {
	const serverInstallDir = `/home/${product.serverDataFolderName}/bin/${commit}`;
	const commitShort = commit.substring(0, 11);
	const tarballName = 'dock-code-reh-linux-x64.tar.gz';

	// Try GitHub Release first — download directly inside the container
	progress.report({ message: 'Downloading server into container...' });
	const releaseTag = `reh-${commitShort}`;
	const downloadUrl = `https://github.com/${REH_GITHUB_REPO}/releases/download/${releaseTag}/${tarballName}`;

	outputChannel.appendLine(`  Trying GitHub Release: ${downloadUrl}`);
	try {
		await sshExec(host, `docker exec ${containerId} sh -c "mkdir -p ${serverInstallDir} && curl -fSL --retry 3 '${downloadUrl}' | tar -xzf - -C ${serverInstallDir} --strip-components=1"`);
		await sshExec(host, `docker exec ${containerId} chmod +x ${serverInstallDir}/bin/${product.serverApplicationName}`);
		outputChannel.appendLine('  Server installed from GitHub Release');
		return;
	} catch {
		outputChannel.appendLine('  GitHub Release not available for this commit');
	}

	// Try latest release
	const latestUrl = `https://github.com/${REH_GITHUB_REPO}/releases/latest/download/${tarballName}`;
	outputChannel.appendLine(`  Trying latest release: ${latestUrl}`);
	try {
		await sshExec(host, `docker exec ${containerId} sh -c "mkdir -p ${serverInstallDir} && curl -fSL --retry 3 '${latestUrl}' | tar -xzf - -C ${serverInstallDir} --strip-components=1"`);
		await sshExec(host, `docker exec ${containerId} chmod +x ${serverInstallDir}/bin/${product.serverApplicationName}`);
		outputChannel.appendLine('  Server installed from latest GitHub Release');
		return;
	} catch {
		outputChannel.appendLine('  Latest release also not available');
	}

	throw new Error(
		'No REH server available. Push to main to trigger GitHub Actions build.\n' +
		`Expected release tag: ${releaseTag}`
	);
}

/**
 * Start REH server inside a container on the remote host.
 */
function startServerInRemoteContainer(
	host: string,
	containerId: string,
	serverBinPath: string,
	connectionToken: string
): Promise<{ port: number; process: cp.ChildProcess }> {
	return new Promise((resolve, reject) => {
		const serverArgs = [
			'--host=0.0.0.0',
			'--port=0',
			`--connection-token=${connectionToken}`,
			'--disable-telemetry',
			'--accept-server-license-terms',
			'--enable-remote-auto-shutdown'
		].join(' ');

		// SSH → docker exec → server
		const proc = cp.spawn('ssh', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ServerAliveInterval=30',
			host,
			`docker exec -i ${containerId} ${serverBinPath} ${serverArgs}`
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let isResolved = false;
		let lastLine = '';

		function processOutput(data: Buffer) {
			const text = data.toString();
			outputChannel.append(`[container-server] ${text}`);

			for (let i = 0; i < text.length; i++) {
				if (text.charCodeAt(i) === 10) {
					const match = lastLine.match(/Extension host agent listening on (\d+)/);
					if (match && !isResolved) {
						isResolved = true;
						resolve({ port: parseInt(match[1], 10), process: proc });
					}
					lastLine = '';
				} else {
					lastLine += text.charAt(i);
				}
			}
		}

		proc.stdout!.on('data', processOutput);
		proc.stderr!.on('data', processOutput);
		proc.on('error', (err) => { if (!isResolved) { isResolved = true; reject(err); } });
		proc.on('close', (code) => { if (!isResolved) { isResolved = true; reject(new Error(`Server exited (code ${code})`)); } });
		setTimeout(() => { if (!isResolved) { isResolved = true; proc.kill(); reject(new Error('Timeout')); } }, 120000);
	});
}

/**
 * Get the host-side port that maps to a container port.
 * Uses `docker port` on the remote, or falls back to the same port via docker network.
 */
async function getRemoteContainerPortMapping(host: string, containerId: string, containerPort: number): Promise<number> {
	// The server listens on 0.0.0.0:PORT inside the container.
	// Since we didn't publish the port, we access it via the container's IP on the docker network.
	// Get container IP and use that port directly.
	const containerIp = (await sshExec(host,
		`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${containerId}`
	)).trim();

	if (containerIp) {
		outputChannel.appendLine(`  Container IP: ${containerIp}, port: ${containerPort}`);
		// Set up a socat relay on the remote host to forward from a host port to the container
		const relayPort = 30000 + Math.floor(Math.random() * 10000);
		// Start a background socat on the remote to relay host:relayPort → container:containerPort
		await sshExec(host,
			`nohup socat TCP-LISTEN:${relayPort},fork,reuseaddr TCP:${containerIp}:${containerPort} > /dev/null 2>&1 & echo $!`
		);
		return relayPort;
	}

	// Fallback: assume container port is directly accessible
	return containerPort;
}

/**
 * Create an SSH tunnel with verified connectivity.
 */
function createSSHTunnel(host: string, localPort: number, remotePort: number): Promise<cp.ChildProcess> {
	return new Promise((resolve, reject) => {
		const proc = cp.spawn('ssh', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ServerAliveInterval=30',
			'-o', 'ExitOnForwardFailure=yes',
			'-N',
			'-L', `${localPort}:127.0.0.1:${remotePort}`,
			host
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		proc.stderr!.on('data', (data: Buffer) => {
			outputChannel.append(`[tunnel] ${data.toString()}`);
		});
		proc.on('error', (err) => reject(new Error(`SSH tunnel failed: ${err.message}`)));

		// Verify tunnel
		const verify = async () => {
			for (let i = 0; i < 20; i++) {
				if (proc.exitCode !== null) {
					throw new Error(`SSH tunnel exited (code ${proc.exitCode})`);
				}
				try {
					await new Promise<void>((res, rej) => {
						const s = net.createConnection(localPort, '127.0.0.1', () => { s.destroy(); res(); });
						s.on('error', rej);
						s.setTimeout(500, () => { s.destroy(); rej(new Error('timeout')); });
					});
					return;
				} catch {
					await new Promise(r => setTimeout(r, 500));
				}
			}
			throw new Error('SSH tunnel not ready');
		};

		setTimeout(async () => {
			try {
				await verify();
				resolve(proc);
			} catch (err: any) {
				proc.kill();
				reject(err);
			}
		}, 200);
	});
}

function findFreePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const server = net.createServer();
		server.listen(0, '127.0.0.1', () => {
			const addr = server.address();
			if (addr && typeof addr !== 'string') {
				server.close(() => resolve(addr.port));
			} else {
				server.close(() => reject(new Error('No port')));
			}
		});
		server.on('error', reject);
	});
}

async function getLocalCommit(context: vscode.ExtensionContext): Promise<string> {
	try {
		return cp.execSync('git rev-parse HEAD', {
			cwd: path.resolve(path.join(context.extensionPath, '..', '..')),
			encoding: 'utf8'
		}).trim();
	} catch {
		return 'dev';
	}
}

export function deactivate() {
	for (const [, procs] of activeProcesses) {
		procs.forEach(p => p.kill());
	}
	activeProcesses.clear();
}
