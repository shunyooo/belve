/*---------------------------------------------------------------------------------------------
 *  dock-code Remote - Containers Extension
 *  Opens folders in Dev Containers using @devcontainers/cli and dock-code REH server.
 *--------------------------------------------------------------------------------------------*/

import * as vscode from 'vscode';
import * as cp from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import * as crypto from 'crypto';
import * as net from 'net';

let outputChannel: vscode.OutputChannel;

/** Active container processes per authority */
const activeProcesses = new Map<string, cp.ChildProcess>();

export function activate(context: vscode.ExtensionContext) {
	outputChannel = vscode.window.createOutputChannel('Remote - Containers');

	// Register the remote authority resolver for 'dev-container'
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

	// Command: Open Folder in Container
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.openInContainer', async () => {
		const folderUri = await vscode.window.showOpenDialog({
			canSelectFolders: true,
			canSelectFiles: false,
			canSelectMany: false,
			openLabel: 'Open in Container',
			title: 'Select a folder with devcontainer.json'
		});

		if (folderUri && folderUri[0]) {
			const folderPath = folderUri[0].fsPath;
			// Check for devcontainer.json
			const hasConfig = findDevcontainerConfig(folderPath);
			if (!hasConfig) {
				const create = await vscode.window.showWarningMessage(
					'No devcontainer.json found. Create a default one?',
					'Create', 'Cancel'
				);
				if (create === 'Create') {
					createDefaultDevcontainerConfig(folderPath);
				} else {
					return;
				}
			}

			// Encode folder path as hex for the authority
			const authorityId = Buffer.from(folderPath).toString('hex');
			await vscode.commands.executeCommand('vscode.newWindow', {
				remoteAuthority: `dev-container+${authorityId}`,
				reuseWindow: true
			});
		}
	}));

	// Command: Rebuild Container
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.rebuildContainer', async () => {
		const authority = vscode.env.remoteName;
		if (!authority) {
			return;
		}
		// Kill existing processes
		const proc = activeProcesses.get(authority);
		if (proc) {
			proc.kill();
			activeProcesses.delete(authority);
		}
		// Reload to trigger re-resolve
		await vscode.commands.executeCommand('workbench.action.reloadWindow');
	}));

	// Command: Show Log
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-containers.showLog', () => {
		outputChannel.show();
	}));

	context.subscriptions.push({
		dispose: () => {
			for (const [, proc] of activeProcesses) {
				proc.kill();
			}
			activeProcesses.clear();
		}
	});
}

/**
 * Check if a devcontainer.json exists in the folder.
 */
function findDevcontainerConfig(folderPath: string): boolean {
	const candidates = [
		path.join(folderPath, '.devcontainer', 'devcontainer.json'),
		path.join(folderPath, '.devcontainer.json'),
	];
	return candidates.some(p => fs.existsSync(p));
}

/**
 * Create a default devcontainer.json.
 */
function createDefaultDevcontainerConfig(folderPath: string): void {
	const devcontainerDir = path.join(folderPath, '.devcontainer');
	if (!fs.existsSync(devcontainerDir)) {
		fs.mkdirSync(devcontainerDir, { recursive: true });
	}
	const config = {
		name: path.basename(folderPath),
		image: 'mcr.microsoft.com/devcontainers/base:ubuntu'
	};
	fs.writeFileSync(
		path.join(devcontainerDir, 'devcontainer.json'),
		JSON.stringify(config, null, '\t') + '\n'
	);
	outputChannel.appendLine(`Created default devcontainer.json at ${devcontainerDir}`);
}

/**
 * Get product configuration from the local product.json.
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
 * Main resolve function.
 */
async function doResolve(
	authority: string,
	progress: vscode.Progress<{ message?: string }>,
	context: vscode.ExtensionContext
): Promise<vscode.ResolverResult> {
	// Parse authority: dev-container+<hex-encoded-folder-path>
	const hexPath = authority.substring(authority.indexOf('+') + 1);
	const folderPath = Buffer.from(hexPath, 'hex').toString('utf8');
	outputChannel.appendLine(`[${new Date().toISOString()}] Resolving Dev Container for: ${folderPath}`);

	const connectionToken = crypto.randomBytes(20).toString('hex');
	const product = getProductConfig();
	const commit = product.commit || await getLocalCommit(context);

	// Step 1: Start/build the dev container
	progress.report({ message: 'Starting Dev Container...' });
	const containerId = await startDevContainer(folderPath);
	outputChannel.appendLine(`Container started: ${containerId}`);

	// Step 2: Install REH server in the container
	progress.report({ message: 'Installing dock-code server...' });
	await installServerInContainer(containerId, commit, product, context);

	// Step 3: Start the server inside the container
	progress.report({ message: 'Starting remote server...' });
	const serverBinPath = `/home/${product.serverDataFolderName}/bin/${commit}/bin/${product.serverApplicationName}`;
	const { port: containerPort, process: serverProcess } = await startServerInContainer(
		containerId, serverBinPath, connectionToken
	);

	activeProcesses.set(authority, serverProcess);
	context.subscriptions.push({
		dispose: () => {
			serverProcess.kill();
			activeProcesses.delete(authority);
		}
	});

	// Step 4: Set up port forwarding from host to container
	progress.report({ message: 'Setting up connection...' });
	const localPort = await findFreePort();
	const portForwardProcess = await createDockerPortForward(containerId, localPort, containerPort);

	context.subscriptions.push({
		dispose: () => {
			portForwardProcess.kill();
		}
	});

	outputChannel.appendLine(`Connection established: localhost:${localPort} -> container:${containerPort}`);

	return new vscode.ResolvedAuthority('127.0.0.1', localPort, connectionToken);
}

/**
 * Start or build the dev container using devcontainer CLI.
 */
async function startDevContainer(folderPath: string): Promise<string> {
	outputChannel.appendLine(`Running: devcontainer up --workspace-folder ${folderPath}`);

	return new Promise((resolve, reject) => {
		const proc = cp.spawn('devcontainer', [
			'up',
			'--workspace-folder', folderPath
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let stdout = '';
		let stderr = '';

		proc.stdout.on('data', (data: Buffer) => {
			const text = data.toString();
			stdout += text;
			outputChannel.append(`[devcontainer] ${text}`);
		});

		proc.stderr.on('data', (data: Buffer) => {
			const text = data.toString();
			stderr += text;
			outputChannel.append(`[devcontainer:err] ${text}`);
		});

		proc.on('close', (code) => {
			if (code === 0) {
				// Parse the JSON output to get container ID
				try {
					const result = JSON.parse(stdout.trim().split('\n').pop() || '{}');
					if (result.containerId) {
						resolve(result.containerId);
					} else {
						reject(new Error('devcontainer up did not return containerId'));
					}
				} catch {
					reject(new Error(`Failed to parse devcontainer output: ${stdout}`));
				}
			} else {
				reject(new Error(`devcontainer up failed (code ${code}): ${stderr}`));
			}
		});

		proc.on('error', (err) => {
			reject(new Error(`Failed to run devcontainer CLI: ${err.message}`));
		});
	});
}

/**
 * Install the REH server inside the container.
 */
async function installServerInContainer(
	containerId: string,
	commit: string,
	product: { serverDataFolderName: string; serverApplicationName: string },
	context: vscode.ExtensionContext
): Promise<void> {
	const serverInstallDir = `/home/${product.serverDataFolderName}/bin/${commit}`;
	const serverBinPath = `${serverInstallDir}/bin/${product.serverApplicationName}`;

	// Check if server already exists in container
	try {
		await dockerExec(containerId, `test -f ${serverBinPath}`);
		outputChannel.appendLine('Server already installed in container');
		return;
	} catch {
		// Not installed yet
	}

	// Find local REH build
	const vscodePath = path.resolve(path.join(context.extensionPath, '..', '..'));

	// Detect container architecture
	const archOutput = await dockerExec(containerId, 'uname -m');
	const arch = archOutput.trim();
	let rehArch = 'x64';
	if (arch.includes('aarch64') || arch.includes('arm64')) {
		rehArch = 'arm64';
	}

	const buildDir = path.join(path.dirname(vscodePath), `vscode-reh-linux-${rehArch}`);

	if (!fs.existsSync(buildDir)) {
		throw new Error(
			`No dock-code REH server build found at ${buildDir}.\n` +
			`Build it with: npm run gulp vscode-reh-linux-${rehArch}`
		);
	}

	outputChannel.appendLine(`Copying REH server from ${buildDir} to container...`);

	// Create target directory in container
	await dockerExec(containerId, `mkdir -p ${serverInstallDir}`);

	// Copy REH build into container using docker cp
	await new Promise<void>((resolve, reject) => {
		const proc = cp.spawn('docker', [
			'cp', `${buildDir}/.`, `${containerId}:${serverInstallDir}/`
		]);
		let stderr = '';
		proc.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });
		proc.on('close', (code) => {
			if (code === 0) {
				resolve();
			} else {
				reject(new Error(`docker cp failed: ${stderr}`));
			}
		});
		proc.on('error', reject);
	});

	// Make server executable
	await dockerExec(containerId, `chmod +x ${serverBinPath}`);
	outputChannel.appendLine('Server installed in container');
}

/**
 * Execute a command inside a Docker container.
 */
function dockerExec(containerId: string, command: string): Promise<string> {
	return new Promise((resolve, reject) => {
		const proc = cp.spawn('docker', [
			'exec', containerId, 'sh', '-c', command
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let stdout = '';
		let stderr = '';
		proc.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
		proc.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });

		proc.on('close', (code) => {
			if (code === 0) {
				resolve(stdout);
			} else {
				reject(new Error(`docker exec failed (code ${code}): ${stderr}`));
			}
		});
		proc.on('error', reject);
	});
}

/**
 * Start the REH server inside the container.
 */
function startServerInContainer(
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

		const proc = cp.spawn('docker', [
			'exec', '-i', containerId, 'sh', '-c',
			`${serverBinPath} ${serverArgs}`
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
						const port = parseInt(match[1], 10);
						outputChannel.appendLine(`Container server listening on port ${port}`);
						resolve({ port, process: proc });
					}
					lastLine = '';
				} else {
					lastLine += text.charAt(i);
				}
			}
		}

		proc.stdout!.on('data', processOutput);
		proc.stderr!.on('data', processOutput);

		proc.on('error', (err) => {
			if (!isResolved) {
				isResolved = true;
				reject(new Error(`Failed to start container server: ${err.message}`));
			}
		});

		proc.on('close', (code) => {
			if (!isResolved) {
				isResolved = true;
				reject(new Error(`Container server exited with code ${code}`));
			}
		});

		setTimeout(() => {
			if (!isResolved) {
				isResolved = true;
				proc.kill();
				reject(new Error('Timeout waiting for container server to start'));
			}
		}, 120000); // 2 minutes for container builds
	});
}

/**
 * Forward a local port to a container port using docker exec + socat or SSH tunnel.
 * Uses a simple TCP proxy since docker port forwarding is more reliable.
 */
function createDockerPortForward(containerId: string, localPort: number, containerPort: number): Promise<cp.ChildProcess> {
	return new Promise((resolve, reject) => {
		// Use a Node.js TCP proxy to forward from localhost to container
		const server = net.createServer((clientSocket) => {
			// For each incoming connection, create a docker exec + socat connection
			const dockerProc = cp.spawn('docker', [
				'exec', '-i', containerId, 'sh', '-c',
				`cat < /dev/tcp/127.0.0.1/${containerPort} & cat > /dev/tcp/127.0.0.1/${containerPort}`
			], { stdio: ['pipe', 'pipe', 'pipe'] });

			// Actually, /dev/tcp might not work. Use socat or a simpler approach.
			dockerProc.kill();
			clientSocket.destroy();
		});

		// Better approach: use docker exec with socat, or just use docker port mapping
		// For simplicity, use docker's built-in port publishing via iptables
		// Since the container is already running, we can use `docker exec` with netcat

		// Simplest reliable approach: use a background `docker exec` with port forwarding
		server.close();

		// Use SSH-style approach: spawn a process that forwards data
		const proc = cp.spawn('docker', [
			'exec', '-i', containerId,
			'sh', '-c', `socat TCP-LISTEN:${containerPort + 10000},fork TCP:127.0.0.1:${containerPort} &
			echo ready`
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		// Actually, the simplest approach: since docker networking allows host access,
		// just expose the port via `docker port` or use docker proxy
		proc.kill();

		// Most reliable: create a local TCP proxy that connects to container
		const proxyServer = net.createServer((clientSocket) => {
			const dockerConn = cp.spawn('docker', [
				'exec', '-i', containerId, 'socat', '-', `TCP:127.0.0.1:${containerPort}`
			], { stdio: ['pipe', 'pipe', 'pipe'] });

			clientSocket.pipe(dockerConn.stdin!);
			dockerConn.stdout!.pipe(clientSocket);

			dockerConn.stderr!.on('data', (d: Buffer) => {
				outputChannel.append(`[proxy:err] ${d.toString()}`);
			});

			clientSocket.on('close', () => dockerConn.kill());
			dockerConn.on('close', () => clientSocket.destroy());
			clientSocket.on('error', () => dockerConn.kill());
			dockerConn.on('error', () => clientSocket.destroy());
		});

		proxyServer.listen(localPort, '127.0.0.1', () => {
			outputChannel.appendLine(`Port forward proxy listening on localhost:${localPort} -> container:${containerPort}`);
			// Return a fake child process that represents the proxy
			const fakeProc = cp.spawn('sleep', ['infinity']);
			fakeProc.on('close', () => proxyServer.close());
			resolve(fakeProc);
		});

		proxyServer.on('error', (err) => {
			reject(new Error(`Port forward proxy failed: ${err.message}`));
		});
	});
}

/**
 * Get the local git commit hash.
 */
async function getLocalCommit(context: vscode.ExtensionContext): Promise<string> {
	const vscodePath = path.resolve(path.join(context.extensionPath, '..', '..'));
	try {
		return cp.execSync('git rev-parse HEAD', { cwd: vscodePath, encoding: 'utf8' }).trim();
	} catch {
		return 'dev';
	}
}

/**
 * Find a free port on the local machine.
 */
function findFreePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const server = net.createServer();
		server.listen(0, '127.0.0.1', () => {
			const address = server.address();
			if (address && typeof address !== 'string') {
				const port = address.port;
				server.close(() => resolve(port));
			} else {
				server.close(() => reject(new Error('Could not find free port')));
			}
		});
		server.on('error', reject);
	});
}

export function deactivate() {
	for (const [, proc] of activeProcesses) {
		proc.kill();
	}
	activeProcesses.clear();
}
