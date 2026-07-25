import Foundation

/// pane 1 枚に対応する belve-persist セッション名を決める単一の真実。
/// 端末 spawn (XTermTerminalView) と「使用中セッション判定」(チューザ) が
/// 同じ規則を使うため、ここに集約する。
enum PaneSessionNaming {
	/// ユーザー入力のセッション名を socket ファイル名 / tmux セッション名に
	/// 使える token へ正規化する。許可外文字は `-` に置換、前後の `-` は除去。
	/// 空 (または全て不正文字) の場合は nil を返し、呼び出し側は自動命名へ倒す。
	static func sanitizedToken(_ raw: String?) -> String? {
		guard let raw else { return nil }
		let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
		let mapped = String(raw.map { allowed.contains($0) ? $0 : "-" })
		let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
		return trimmed.isEmpty ? nil : trimmed
	}

	/// pane の overrideSocket / sessionNameOverride / paneId から確定するセッション名。
	/// 優先順位: 既存 attach (overrideSocket) → ユーザー命名 → paneId 由来の自動命名。
	static func sessionName(projShort: String, paneIdString: String, sessionNameOverride: String?, overrideSocket: String?) -> String {
		if let override = overrideSocket, !override.isEmpty {
			return (override as NSString).lastPathComponent.replacingOccurrences(of: ".sock", with: "")
		}
		if let token = sanitizedToken(sessionNameOverride) {
			return "belve-\(projShort)-\(token)"
		}
		return "belve-\(projShort)-\(String(paneIdString.prefix(8)))"
	}

	/// セッション名から標準の socket パスを導く。
	static func socketPath(for sessionName: String) -> String {
		"/tmp/belve-shell/sessions/\(sessionName).sock"
	}
}
