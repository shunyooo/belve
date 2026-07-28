import Foundation

/// ローカル (Mac) の claude セッションでも agent-watch フックが効くようにする起動時セットアップ。
///
/// agent-watch フックはグローバル `~/.claude/settings.json` に
/// `~/.belve/bin/belve claude-hook <sub>` として登録される (`claude-hooks-install`)。
/// これで claude の起動経路 (Belve / 生ターミナル / モバイル) に依らず全 claude が
/// 起動時にフックを読む。リモートでは `belve-setup` が同じ事をするが、ローカルには
/// `belve-setup` が走らないため、Mac 側ではアプリ起動時にここで:
///   (1) グローバル hook が参照する `~/.belve/bin` に必要スクリプトを stage する
///   (2) `claude-hooks-install` を実行して `settings.json` に merge する
/// を行う。両方 idempotent。
///
/// 注意: これはユーザーの Mac の **グローバル** `~/.claude/settings.json` を書き換える。
/// 他ツールのエントリ / 他のトップレベルキーは temper しない (marker で自分のだけ入替)。
/// 解除は `~/.belve/bin/claude-hooks-install --uninstall`。
enum LocalHooksInstaller {
	/// hook が参照する `~/.belve/bin` を stage し、`claude-hooks-install` で merge する。
	/// ファイル IO と python3 実行を含むので起動スレッドから外して呼ぶこと。
	static func install() {
		guard let bundleBin = bundleBinDir() else {
			NSLog("[Belve] LocalHooksInstaller: bundle bin dir not found; skip")
			return
		}
		let destBin = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".belve/bin")
		do {
			try FileManager.default.createDirectory(at: destBin, withIntermediateDirectories: true)
		} catch {
			NSLog("[Belve] LocalHooksInstaller: mkdir ~/.belve/bin failed: \(error.localizedDescription)")
			return
		}

		// グローバル hook (`belve claude-hook`) 本体と installer、および wrapper 一式を
		// stage する。hook が参照する belve と、それを merge する claude-hooks-install が
		// 必須。他は経路統一のため併せて配置 (latent な local codex path 破綻も解消)。
		for name in ["belve", "claude", "codex", "claude-hooks-install", "codex-hooks-install"] {
			let src = bundleBin.appendingPathComponent(name)
			guard FileManager.default.fileExists(atPath: src.path) else { continue }
			let dst = destBin.appendingPathComponent(name)
			try? FileManager.default.removeItem(at: dst)
			do {
				try FileManager.default.copyItem(at: src, to: dst)
				try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst.path)
			} catch {
				NSLog("[Belve] LocalHooksInstaller: stage %@ failed: %@", name, error.localizedDescription)
			}
		}

		let installer = destBin.appendingPathComponent("claude-hooks-install")
		guard FileManager.default.fileExists(atPath: installer.path) else {
			NSLog("[Belve] LocalHooksInstaller: claude-hooks-install missing after stage; skip merge")
			return
		}
		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		proc.arguments = ["python3", installer.path]
		do {
			try proc.run()
			proc.waitUntilExit()
			if proc.terminationStatus != 0 {
				NSLog("[Belve] LocalHooksInstaller: claude-hooks-install exited %d", proc.terminationStatus)
			}
		} catch {
			NSLog("[Belve] LocalHooksInstaller: run claude-hooks-install failed: %@", error.localizedDescription)
		}
	}

	/// バンドル内 `Resources/bin`。production (.app) を優先し、swift run 開発時は
	/// repo の `Sources/Belve/Resources/bin` に fallback する。
	private static func bundleBinDir() -> URL? {
		if let resourceURL = Bundle.main.resourceURL {
			let bundleBin = resourceURL.appendingPathComponent("bin")
			if FileManager.default.fileExists(atPath: bundleBin.appendingPathComponent("belve").path) {
				return bundleBin
			}
		}
		if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
			let dev = execDir
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.deletingLastPathComponent()
				.appendingPathComponent("Sources/Belve/Resources/bin")
			if FileManager.default.fileExists(atPath: dev.appendingPathComponent("belve").path) {
				return dev
			}
		}
		return nil
	}
}
