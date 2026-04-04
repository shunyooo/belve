import Foundation

struct SSHHost: Identifiable {
	let id = UUID()
	let name: String
	let hostname: String?
	let user: String?
}

/// Parses ~/.ssh/config to extract host definitions.
enum SSHConfigParser {
	static func parse() -> [SSHHost] {
		let configPath = NSHomeDirectory() + "/.ssh/config"
		guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
			NSLog("[Belve] Could not read ~/.ssh/config")
			return []
		}

		var hosts: [SSHHost] = []
		var currentHost: String?
		var currentHostname: String?
		var currentUser: String?

		for line in content.components(separatedBy: .newlines) {
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

			let parts = trimmed.split(separator: " ", maxSplits: 1).map { String($0) }
			guard parts.count == 2 else { continue }

			let key = parts[0].lowercased()
			let value = parts[1].trimmingCharacters(in: .whitespaces)

			switch key {
			case "host":
				// Save previous host
				if let host = currentHost, host != "*" {
					hosts.append(SSHHost(name: host, hostname: currentHostname, user: currentUser))
				}
				currentHost = value
				currentHostname = nil
				currentUser = nil
			case "hostname":
				currentHostname = value
			case "user":
				currentUser = value
			default:
				break
			}
		}

		// Save last host
		if let host = currentHost, host != "*" {
			hosts.append(SSHHost(name: host, hostname: currentHostname, user: currentUser))
		}

		NSLog("[Belve] Parsed \(hosts.count) SSH hosts from config")
		return hosts
	}
}
