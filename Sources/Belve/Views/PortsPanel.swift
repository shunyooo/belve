import SwiftUI

/// Popover surfaced from the bottom-bar "Ports" item. Lists the project's
/// configured forwards with live status and exposes add/remove/toggle.
struct PortsPanel: View {
	let project: Project
	@ObservedObject var portManager: PortForwardManager
	let onUpdateForwards: ([PortForward]) -> Void
	let onDismiss: () -> Void

	@State private var newLocalText = ""
	@State private var newRemoteText = ""
	@FocusState private var focusedField: FocusField?

	private enum FocusField { case local, remote }

	/// Typing in either field mirrors to the other **only while they were
	/// still tracking**. The moment the user deliberately diverges them, the
	/// mirroring stops — so the natural "type once, both fill" behaviour is
	/// there without losing the ability to set them independently.
	private var localBinding: Binding<String> {
		Binding(
			get: { newLocalText },
			set: { newValue in
				let previous = newLocalText
				newLocalText = newValue
				if newRemoteText.isEmpty || newRemoteText == previous {
					newRemoteText = newValue
				}
			}
		)
	}

	private var remoteBinding: Binding<String> {
		Binding(
			get: { newRemoteText },
			set: { newValue in
				let previous = newRemoteText
				newRemoteText = newValue
				if newLocalText.isEmpty || newLocalText == previous {
					newLocalText = newValue
				}
			}
		)
	}

	private var forwards: [PortForward] { project.portForwards }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			header
			Divider().overlay(Theme.border)
			if forwards.isEmpty {
				emptyState
			} else {
				ScrollView {
					VStack(spacing: 0) {
						ForEach(forwards) { forward in
							row(for: forward)
							Divider().overlay(Theme.borderSubtle.opacity(0.4))
						}
					}
				}
				.frame(maxHeight: 280)
			}
			Divider().overlay(Theme.border)
			addRow
		}
		.frame(width: 340)
		.background(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.fill(.ultraThinMaterial)
				.environment(\.colorScheme, .dark)
		)
		.overlay(
			RoundedRectangle(cornerRadius: Theme.radiusSm)
				.strokeBorder(Theme.border, lineWidth: 1)
		)
		.shadow(color: .black.opacity(0.4), radius: 12, y: 4)
		.padding(4)
	}

	private var header: some View {
		HStack(spacing: 6) {
			Image(systemName: "arrow.left.arrow.right")
				.font(.system(size: 10))
				.foregroundStyle(Theme.accent)
			Text("Port Forwards")
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(Theme.textPrimary)
			Spacer()
			if !project.isRemote {
				Text("Local project")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}

	private var emptyState: some View {
		Text("No forwards yet. Add one below.")
			.font(.system(size: 10))
			.foregroundStyle(Theme.textTertiary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 10)
			.padding(.vertical, 14)
	}

	@ViewBuilder
	private func row(for forward: PortForward) -> some View {
		let status = portManager.status(for: project.id, forwardId: forward.id)
		HStack(spacing: 8) {
			statusDot(for: status)
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 6) {
					portLabel(title: "LOCAL", port: forward.localPort)
					Image(systemName: "arrow.right")
						.font(.system(size: 8))
						.foregroundStyle(Theme.textTertiary)
					portLabel(title: "REMOTE", port: forward.remotePort)
					if forward.autoDetected {
						Text("auto")
							.font(.system(size: 8, weight: .semibold))
							.foregroundStyle(Theme.textTertiary)
							.padding(.horizontal, 4)
							.padding(.vertical, 1)
							.background(RoundedRectangle(cornerRadius: 2).fill(Theme.surfaceActive))
					}
				}
				Text(statusLabel(for: status, forward: forward))
					.font(.system(size: 9))
					.foregroundStyle(statusColor(for: status))
					.lineLimit(1)
			}
			Spacer()
			Toggle(
				"",
				isOn: Binding(
					get: { forward.enabled },
					set: { newValue in updateForward(forward.id) { $0.enabled = newValue } }
				)
			)
			.toggleStyle(.switch)
			.controlSize(.mini)
			.labelsHidden()
			Button(action: { removeForward(forward.id) }) {
				Image(systemName: "xmark")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
					.padding(4)
					.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
	}

	private func portLabel(title: String, port: Int) -> some View {
		VStack(alignment: .leading, spacing: 0) {
			Text(title)
				.font(.system(size: 7, weight: .semibold))
				.tracking(0.6)
				.foregroundStyle(Theme.textTertiary)
			Text("\(port)")
				.font(.system(size: 11, weight: .medium, design: .monospaced))
		}
	}

	private var addRow: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				fieldColumn(title: "LOCAL (Mac)", text: localBinding, focus: .local)
				Image(systemName: "arrow.right")
					.font(.system(size: 9))
					.foregroundStyle(Theme.textTertiary)
					.padding(.top, 11) // align with fields, not labels
				fieldColumn(title: "REMOTE", text: remoteBinding, focus: .remote)
				Spacer()
				Button(action: addForward) {
					Text("Add")
						.font(.system(size: 11, weight: .medium))
						.padding(.horizontal, 10)
						.padding(.vertical, 4)
						.background(RoundedRectangle(cornerRadius: 3).fill(
							(parsedLocal == nil || parsedRemote == nil) ? Theme.surfaceActive : Theme.accent.opacity(0.9)
						))
						.foregroundStyle(.white)
				}
				.buttonStyle(.plain)
				.disabled(parsedLocal == nil || parsedRemote == nil)
				.padding(.top, 11)
			}
			Text("Type one port — the other mirrors until you edit it.")
				.font(.system(size: 9))
				.foregroundStyle(Theme.textTertiary)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
	}

	private func fieldColumn(title: String, text: Binding<String>, focus: FocusField) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title)
				.font(.system(size: 7, weight: .semibold))
				.tracking(0.6)
				.foregroundStyle(Theme.textTertiary)
			TextField("port", text: text)
				.textFieldStyle(.plain)
				.font(.system(size: 12, design: .monospaced))
				.padding(.horizontal, 6).padding(.vertical, 4)
				.background(RoundedRectangle(cornerRadius: 3).fill(Theme.surfaceActive))
				.frame(width: 72)
				.focused($focusedField, equals: focus)
				.onSubmit(addForward)
		}
	}

	private var parsedLocal: Int? { Int(newLocalText.trimmingCharacters(in: .whitespaces)) }
	private var parsedRemote: Int? { Int(newRemoteText.trimmingCharacters(in: .whitespaces)) }

	private func addForward() {
		guard let local = parsedLocal, let remote = parsedRemote else { return }
		guard local > 0 && local < 65536 && remote > 0 && remote < 65536 else { return }
		var updated = project.portForwards
		updated.append(PortForward(localPort: local, remotePort: remote))
		onUpdateForwards(updated)
		newLocalText = ""
		newRemoteText = ""
		focusedField = .local
	}

	private func removeForward(_ id: UUID) {
		onUpdateForwards(project.portForwards.filter { $0.id != id })
	}

	private func updateForward(_ id: UUID, _ mutate: (inout PortForward) -> Void) {
		var updated = project.portForwards
		guard let idx = updated.firstIndex(where: { $0.id == id }) else { return }
		mutate(&updated[idx])
		onUpdateForwards(updated)
	}

	// MARK: - Status display

	private func statusDot(for status: PortForwardManager.Status?) -> some View {
		Circle()
			.fill(statusColor(for: status))
			.frame(width: 7, height: 7)
	}

	private func statusColor(for status: PortForwardManager.Status?) -> Color {
		guard let status else { return Theme.textTertiary }
		switch status {
		case .establishing: return Theme.yellow
		case .active: return Theme.green
		case .remapped: return Theme.green
		case .conflict: return Theme.red
		case .unreachable: return Theme.yellow
		case .error: return Theme.red
		}
	}

	private func statusLabel(for status: PortForwardManager.Status?, forward: PortForward) -> String {
		guard forward.enabled else { return "disabled" }
		switch status {
		case .none: return "—"
		case .some(.establishing): return "establishing…"
		case .some(.active): return "listening"
		case .some(.remapped(let actual)): return "remapped → :\(actual)"
		case .some(.conflict): return "local port in use"
		case .some(.unreachable): return "no service responding"
		case .some(.error(let msg)): return msg
		}
	}
}
