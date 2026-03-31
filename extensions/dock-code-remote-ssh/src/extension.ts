/*---------------------------------------------------------------------------------------------
 *  dock-code Remote - SSH Extension
 *  Opens folders on remote machines via SSH using the dock-code REH server.
 *--------------------------------------------------------------------------------------------*/

import * as vscode from 'vscode';
import * as cp from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import * as crypto from 'crypto';

let outputChannel: vscode.OutputChannel;

/** Active SSH processes per authority, for cleanup on deactivate */
const activeProcesses = new Map<string, cp.ChildProcess>();

export function activate(context: vscode.ExtensionContext) {

	outputChannel = vscode.window.createOutputChannel('Remote - SSH');

	// Register the remote authority resolver for 'ssh-remote'
	const resolverDisposable = vscode.workspace.registerRemoteAuthorityResolver('ssh-remote', {
		async getCanonicalURI(uri: vscode.Uri): Promise<vscode.Uri> {
			return vscode.Uri.file(uri.path);
		},
		resolve(authority: string): Thenable<vscode.ResolverResult> {
			return vscode.window.withProgress({
				location: vscode.ProgressLocation.Notification,
				title: `Connecting to SSH host ([show log](command:dock-code-remote-ssh.showLog))`,
				cancellable: false
			}, (progress) => doResolve(authority, progress, context));
		}
	});
	context.subscriptions.push(resolverDisposable);

	// Command: Connect to Host (new window)
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-ssh.connect', async () => {
		const host = await pickHost();
		if (host) {
			await vscode.commands.executeCommand('vscode.newWindow', {
				remoteAuthority: `ssh-remote+${host}`
			});
		}
	}));

	// Command: Connect to Host (current window)
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-ssh.connectInCurrentWindow', async () => {
		const host = await pickHost();
		if (host) {
			await vscode.commands.executeCommand('vscode.newWindow', {
				remoteAuthority: `ssh-remote+${host}`,
				reuseWindow: true
			});
		}
	}));

	// Command: Show Log
	context.subscriptions.push(vscode.commands.registerCommand('dock-code-remote-ssh.showLog', () => {
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
 * Prompt the user to select or enter an SSH host.
 * Reads hosts from ~/.ssh/config.
 */
async function pickHost(): Promise<string | undefined> {
	const hosts = parseSSHConfigHosts();
	const items: vscode.QuickPickItem[] = hosts.map(h => ({ label: h }));
	items.push({ label: '$(plus) Enter host manually...', description: 'user@hostname' });

	const selected = await vscode.window.showQuickPick(items, {
		placeHolder: 'Select an SSH host to connect to',
		title: 'Remote-SSH: Connect to Host'
	});

	if (!selected) {
		return undefined;
	}

	if (selected.label.includes('Enter host manually')) {
		return vscode.window.showInputBox({
			prompt: 'Enter SSH host (e.g., user@hostname or hostname)',
			placeHolder: 'user@hostname'
		});
	}

	return selected.label;
}

/**
 * Parse SSH config file to extract host names.
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
			const hostPatterns = match[1].trim().split(/\s+/);
			for (const pattern of hostPatterns) {
				// Skip wildcard patterns
				if (!pattern.includes('*') && !pattern.includes('?')) {
					hosts.push(pattern);
				}
			}
		}
	}
	return hosts;
}

/**
 * Get product configuration from the local product.json.
 */
function getProductConfig(): { commit?: string; quality?: string; serverApplicationName: string; serverDataFolderName: string; version: string } {
	const productPath = path.join(vscode.env.appRoot, 'product.json');
	const content = JSON.parse(fs.readFileSync(productPath, 'utf8'));
	return {
		commit: content.commit,
		quality: content.quality,
		serverApplicationName: content.serverApplicationName || 'dock-code-server',
		serverDataFolderName: content.serverDataFolderName || '.dock-code-server',
		version: content.version || '0.0.0'
	};
}

/**
 * Detect the remote platform and architecture via SSH.
 */
async function detectRemotePlatform(host: string): Promise<{ os: string; arch: string }> {
	const result = await sshExec(host, 'uname -s && uname -m');
	const lines = result.trim().split('\n');
	const osName = lines[0]?.toLowerCase() || 'linux';
	const archName = lines[1]?.toLowerCase() || 'x86_64';

	let remoteOs = 'linux';
	if (osName.includes('darwin')) {
		remoteOs = 'darwin';
	}

	let remoteArch = 'x64';
	if (archName.includes('aarch64') || archName.includes('arm64')) {
		remoteArch = 'arm64';
	} else if (archName.includes('armv7') || archName.includes('armhf')) {
		remoteArch = 'armhf';
	}

	return { os: remoteOs, arch: remoteArch };
}

/**
 * Execute a command on the remote via SSH and return stdout.
 */
function sshExec(host: string, command: string): Promise<string> {
	return new Promise((resolve, reject) => {
		const proc = cp.spawn('ssh', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ConnectTimeout=15',
			host,
			command
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let stdout = '';
		let stderr = '';
		proc.stdout.on('data', (data: Buffer) => { stdout += data.toString(); });
		proc.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });

		proc.on('close', (code) => {
			if (code === 0) {
				resolve(stdout);
			} else {
				reject(new Error(`SSH command failed (code ${code}): ${stderr}`));
			}
		});

		proc.on('error', (err) => {
			reject(new Error(`SSH failed: ${err.message}`));
		});
	});
}

/**
 * Main resolve function: connects to the remote, installs server, starts it,
 * sets up SSH tunnel, and returns ResolvedAuthority.
 */
async function doResolve(
	authority: string,
	progress: vscode.Progress<{ message?: string }>,
	context: vscode.ExtensionContext
): Promise<vscode.ResolverResult> {
	// Parse authority: ssh-remote+user@host or ssh-remote+host
	const host = authority.substring(authority.indexOf('+') + 1);
	outputChannel.appendLine(`[${new Date().toISOString()}] Resolving SSH remote: ${host}`);

	const connectionToken = crypto.randomBytes(20).toString('hex');
	const product = getProductConfig();

	// Step 1: Test SSH connectivity
	progress.report({ message: 'Testing SSH connection...' });
	outputChannel.appendLine(`Testing SSH connection to ${host}...`);
	try {
		await sshExec(host, 'echo ok');
		outputChannel.appendLine('SSH connection successful');
	} catch (err: any) {
		outputChannel.appendLine(`SSH connection failed: ${err.message}`);
		throw vscode.RemoteAuthorityResolverError.NotAvailable(
			`Could not connect to "${host}": ${err.message}`, true
		);
	}

	// Step 2: Detect remote platform
	progress.report({ message: 'Detecting remote platform...' });
	const remote = await detectRemotePlatform(host);
	outputChannel.appendLine(`Remote platform: ${remote.os}-${remote.arch}`);

	// Step 3: Check if server is already installed
	progress.report({ message: 'Checking server installation...' });
	const commit = product.commit || await getLocalCommit(context);
	const serverInstallDir = `~/${product.serverDataFolderName}/bin/${commit}`;
	const serverBinPath = `${serverInstallDir}/bin/${product.serverApplicationName}`;

	const serverExists = await checkRemoteFileExists(host, serverBinPath);

	if (!serverExists) {
		// Step 4: Install server on remote
		progress.report({ message: 'Installing dock-code server on remote...' });
		await installServerOnRemote(host, commit, remote, product, context, progress);
	} else {
		outputChannel.appendLine(`Server already installed at ${serverInstallDir}`);
	}

	// Step 5: Start the server on the remote
	progress.report({ message: 'Starting remote server...' });
	const { port: remotePort, process: serverProcess } = await startRemoteServer(
		host, serverBinPath, connectionToken
	);

	// Track the process for cleanup
	activeProcesses.set(authority, serverProcess);
	context.subscriptions.push({
		dispose: () => {
			serverProcess.kill();
			activeProcesses.delete(authority);
		}
	});

	// Step 6: Set up SSH port forwarding
	progress.report({ message: 'Setting up tunnel...' });
	const localPort = await findFreePort();
	const tunnelProcess = await createSSHTunnel(host, localPort, remotePort);

	context.subscriptions.push({
		dispose: () => {
			tunnelProcess.kill();
		}
	});

	outputChannel.appendLine(`Tunnel established: localhost:${localPort} -> ${host}:${remotePort}`);
	outputChannel.appendLine(`Connection token: ${connectionToken.substring(0, 8)}...`);

	return new vscode.ResolvedAuthority('127.0.0.1', localPort, connectionToken);
}

/**
 * Get the local git commit hash (for dev mode).
 */
async function getLocalCommit(context: vscode.ExtensionContext): Promise<string> {
	const vscodePath = path.resolve(path.join(context.extensionPath, '..', '..'));
	try {
		const result = cp.execSync('git rev-parse HEAD', {
			cwd: vscodePath,
			encoding: 'utf8'
		}).trim();
		return result;
	} catch {
		return 'dev';
	}
}

/**
 * Check if a file exists on the remote.
 */
async function checkRemoteFileExists(host: string, remotePath: string): Promise<boolean> {
	try {
		await sshExec(host, `test -f ${remotePath} && echo exists`);
		return true;
	} catch {
		return false;
	}
}

/**
 * Install the dock-code server on the remote machine.
 * In dev mode, copies from a local build. In production, downloads from URL.
 */
async function installServerOnRemote(
	host: string,
	commit: string,
	remote: { os: string; arch: string },
	product: { serverDataFolderName: string; serverApplicationName: string },
	context: vscode.ExtensionContext,
	progress: vscode.Progress<{ message?: string }>
): Promise<void> {
	const vscodePath = path.resolve(path.join(context.extensionPath, '..', '..'));
	const buildDir = path.join(path.dirname(vscodePath), `vscode-reh-${remote.os}-${remote.arch}`);

	// Check for local REH build
	if (fs.existsSync(buildDir)) {
		outputChannel.appendLine(`Found local REH build at ${buildDir}`);
		progress.report({ message: 'Uploading server to remote...' });

		// Create tarball of the REH build
		const tarPath = path.join(os.tmpdir(), `dock-code-reh-${commit}.tar.gz`);
		outputChannel.appendLine(`Creating tarball: ${tarPath}`);

		cp.execSync(
			`tar -czf "${tarPath}" -C "${path.dirname(buildDir)}" "${path.basename(buildDir)}"`,
			{ encoding: 'utf8' }
		);

		// Create installation directory on remote
		const remoteInstallDir = `~/${product.serverDataFolderName}/bin/${commit}`;
		await sshExec(host, `mkdir -p ${remoteInstallDir}`);

		// SCP the tarball to remote
		outputChannel.appendLine(`Uploading server to ${host}:${remoteInstallDir}...`);
		await scpFile(host, tarPath, `/tmp/dock-code-reh.tar.gz`);

		// Extract on remote
		outputChannel.appendLine('Extracting server on remote...');
		await sshExec(host, `tar -xzf /tmp/dock-code-reh.tar.gz -C ${remoteInstallDir} --strip-components=1 && rm /tmp/dock-code-reh.tar.gz`);

		// Make server executable
		await sshExec(host, `chmod +x ${remoteInstallDir}/bin/${product.serverApplicationName}`);

		// Clean up local tarball
		fs.unlinkSync(tarPath);

		outputChannel.appendLine('Server installed successfully');
	} else {
		// Check for custom download URL
		const downloadUrl = vscode.workspace.getConfiguration('remote.SSH').get<string>('serverDownloadUrl');
		if (downloadUrl) {
			outputChannel.appendLine(`Downloading server from: ${downloadUrl}`);
			const remoteInstallDir = `~/${product.serverDataFolderName}/bin/${commit}`;
			const url = downloadUrl
				.replace('${commit}', commit)
				.replace('${os}', remote.os)
				.replace('${arch}', remote.arch);
			await sshExec(host, `mkdir -p ${remoteInstallDir} && curl -L "${url}" | tar -xzf - -C ${remoteInstallDir} --strip-components=1`);
			await sshExec(host, `chmod +x ${remoteInstallDir}/bin/${product.serverApplicationName}`);
		} else {
			const message = `No dock-code server found for the remote. Please build it first:\n\nnpm run gulp vscode-reh-${remote.os}-${remote.arch}\n\nExpected build at: ${buildDir}`;
			outputChannel.appendLine(message);
			throw vscode.RemoteAuthorityResolverError.NotAvailable(message, true);
		}
	}
}

/**
 * SCP a file to the remote.
 */
function scpFile(host: string, localPath: string, remotePath: string): Promise<void> {
	return new Promise((resolve, reject) => {
		const proc = cp.spawn('scp', [
			'-o', 'StrictHostKeyChecking=accept-new',
			localPath,
			`${host}:${remotePath}`
		]);

		let stderr = '';
		proc.stderr.on('data', (data: Buffer) => { stderr += data.toString(); });

		proc.on('close', (code) => {
			if (code === 0) {
				resolve();
			} else {
				reject(new Error(`SCP failed (code ${code}): ${stderr}`));
			}
		});

		proc.on('error', (err) => {
			reject(new Error(`SCP failed: ${err.message}`));
		});
	});
}

/**
 * Start the dock-code server on the remote via SSH.
 * Returns the port number the server is listening on.
 */
function startRemoteServer(
	host: string,
	serverBinPath: string,
	connectionToken: string
): Promise<{ port: number; process: cp.ChildProcess }> {
	return new Promise((resolve, reject) => {
		const serverArgs = [
			'--host=127.0.0.1',
			'--port=0',
			`--connection-token=${connectionToken}`,
			'--disable-telemetry',
			'--accept-server-license-terms',
			'--enable-remote-auto-shutdown'
		].join(' ');

		const command = `${serverBinPath} ${serverArgs}`;
		outputChannel.appendLine(`Starting remote server: ${command}`);

		const proc = cp.spawn('ssh', [
			'-o', 'StrictHostKeyChecking=accept-new',
			'-o', 'ServerAliveInterval=30',
			host,
			command
		], { stdio: ['ignore', 'pipe', 'pipe'] });

		let isResolved = false;
		let lastLine = '';

		function processOutput(data: Buffer) {
			const text = data.toString();
			outputChannel.append(`[server] ${text}`);

			for (let i = 0; i < text.length; i++) {
				if (text.charCodeAt(i) === 10) { // LineFeed
					const match = lastLine.match(/Extension host agent listening on (\d+)/);
					if (match && !isResolved) {
						isResolved = true;
						const port = parseInt(match[1], 10);
						outputChannel.appendLine(`Remote server listening on port ${port}`);
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
				reject(new Error(`Failed to start remote server: ${err.message}`));
			}
		});

		proc.on('close', (code) => {
			if (!isResolved) {
				isResolved = true;
				reject(new Error(`Remote server exited with code ${code}`));
			} else {
				outputChannel.appendLine(`Remote server process exited (code ${code})`);
			}
		});

		// Timeout after 60 seconds
		setTimeout(() => {
			if (!isResolved) {
				isResolved = true;
				proc.kill();
				reject(new Error('Timeout waiting for remote server to start'));
			}
		}, 60000);
	});
}

/**
 * Create an SSH tunnel for port forwarding.
 * Verifies the tunnel is operational by testing TCP connectivity.
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

		proc.on('error', (err) => {
			reject(new Error(`SSH tunnel failed: ${err.message}`));
		});

		// Verify tunnel by actually connecting to the forwarded port
		const verifyTunnel = async () => {
			const net = require('net') as typeof import('net');
			for (let attempt = 0; attempt < 20; attempt++) {
				if (proc.exitCode !== null) {
					throw new Error(`SSH tunnel exited with code ${proc.exitCode}`);
				}
				try {
					await new Promise<void>((res, rej) => {
						const socket = net.createConnection(localPort, '127.0.0.1', () => {
							socket.destroy();
							res();
						});
						socket.on('error', rej);
						socket.setTimeout(500, () => {
							socket.destroy();
							rej(new Error('timeout'));
						});
					});
					outputChannel.appendLine(`[tunnel] Verified: localhost:${localPort} -> ${host}:${remotePort} (attempt ${attempt + 1})`);
					return; // tunnel is ready
				} catch {
					await new Promise(r => setTimeout(r, 500));
				}
			}
			throw new Error('SSH tunnel not ready after 10 seconds');
		};

		setTimeout(async () => {
			try {
				await verifyTunnel();
				resolve(proc);
			} catch (err: any) {
				proc.kill();
				reject(err);
			}
		}, 200);
	});
}

/**
 * Find a free port on the local machine.
 */
function findFreePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const net = require('net') as typeof import('net');
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
