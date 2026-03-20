import SwiftUI

private let recentCallTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateFormat = "dd.MM.yyyy, HH:mm"
    return formatter
}()

struct MenuBarView: View {
    @ObservedObject var state: AppState
    let onOpenSettings: () -> Void
    let onOpenAddFavorite: (_ prefilledNumber: String) -> Void
    let onQuit: () -> Void
    @State private var showCallAudioSettings = false

    private let dialPad: [[(number: String, letters: String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SIP Phone")
                    .font(.headline)
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                Button {
                    onQuit()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }

            connectionStatusBanner

            if state.activeCall != nil {
                activeCallPanel
                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField(
                        "Nummer",
                        text: Binding(
                            get: { state.dialedNumber },
                            set: { state.setDialedNumber($0) }
                        )
                    )
                        .textFieldStyle(.roundedBorder)
                    if state.activeCall != nil {
                        Button("Rückfrage") { state.startConsultation() }
                    }
                    Button {
                        state.placeCall()
                    } label: {
                        Image(systemName: "phone")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderless)

                    Button {
                        state.backspace()
                    } label: {
                        Image(systemName: "delete.left")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(dialPad.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.number) { key in
                            DialKeyButton(number: key.number, letters: key.letters) {
                                state.input(key.number)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            deviceSummary

            Divider()

            HStack {
                sectionTitle("Favoriten")
                Spacer()
                Button {
                    onOpenAddFavorite(state.dialedNumber.trimmingCharacters(in: .whitespacesAndNewlines))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }
            if state.favorites.isEmpty {
                Text("Keine Favoriten")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.favorites) { contact in
                            FavoriteRow(contact: contact, state: state)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 180)
            }

            Divider()

            sectionTitle("Letzte Anrufe")
            if state.recentCallsLast7Days.isEmpty {
                Text("Keine Anrufe in den letzten 7 Tagen")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(state.recentCallsLast7Days) { call in
                            RecentCallRow(call: call, state: state)
                        }
                    }
                }
                .frame(height: 180)
            }

        }
        .padding(9)
        .frame(width: 286)
        .onAppear {
            state.refreshPersistedCollections()
            state.markMissedCallIndicatorAsSeen()
        }
    }

    private var deviceSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Speaker: \(state.resolvedDeviceLabel(for: .speaker))")
            Text("Mikrofon: \(state.resolvedDeviceLabel(for: .microphone))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var connectionStatusBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(connectionStatusColor)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text("VoIP: \(state.connectionStatus.title)")
                    .font(.caption.weight(.semibold))
                Text(state.connectionStatus.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var activeCallPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Aktive Gespräche")
                Spacer()
                Button {
                    showCallAudioSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
            }

            if showCallAudioSettings {
                CallAudioSettingsPanel(state: state)
            }

            if let activeCall = state.activeCall {
                ManagedCallCard(
                    title: activeCall.state == .conference ? "Konferenz" : "Hauptgespräch",
                    call: activeCall,
                    endTitle: activeCall.state == .conference ? "Konferenz beenden" : "Auflegen",
                    isMicrophoneMuted: state.isMicrophoneMuted,
                    onToggleMute: { state.toggleMicrophoneMuted() },
                    onEnd: { state.end(.primary) }
                )
            }

            if let consultationCall = state.consultationCall {
                ManagedCallCard(
                    title: "Rückfrage",
                    call: consultationCall,
                    endTitle: "Rückfrage beenden",
                    isMicrophoneMuted: state.isMicrophoneMuted,
                    onToggleMute: { state.toggleMicrophoneMuted() },
                    onEnd: { state.end(.consultation) }
                )

                HStack(spacing: 6) {
                    Button("Transfer") { state.transferActiveCall() }
                    Button("Conference") { state.mergeConference() }
                }
            } else if state.activeCall != nil {
                Text("Nummer eingeben und \"Rückfrage\" wählen, um Transfer oder Konferenz zu starten.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    private var connectionStatusColor: Color {
        switch state.connectionStatus {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .orange
        case .networkUnavailable, .disconnected:
            return .red
        case .invalidConfiguration:
            return .secondary
        }
    }
}

private struct FavoriteRow: View {
    let contact: Contact
    @ObservedObject var state: AppState
    @State private var isHovered = false

    var body: some View {
        HStack {
            if state.shouldShowFavoritePresence(for: contact) {
                Circle()
                    .fill(presenceColor(state.favoritePresenceState(for: contact)))
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.name)
                    .font(.subheadline)
                Text(contact.number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHovered {
                Button {
                    state.removeFavorite(contact.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)

                Button {
                    state.call(contact: contact)
                } label: {
                    Image(systemName: "phone")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func presenceColor(_ state: FavoritePresenceState) -> Color {
        switch state {
        case .online:
            return .green
        case .offline:
            return .red
        case .unknown, .checking:
            return .orange
        }
    }
}

private struct RecentCallRow: View {
    let call: CallRecord
    @ObservedObject var state: AppState
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: directionIcon)
                .foregroundStyle(directionColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(call.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    if call.number != call.displayName {
                        Text(call.number)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if let metadata = call.metadataSummary {
                    Text(metadata)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(recentCallTimestampFormatter.string(from: call.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHovered {
                Button {
                    state.toggleFavorite(for: call.id)
                } label: {
                    Image(systemName: call.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                Button {
                    state.showTranscript(for: call)
                } label: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(call.transcription == nil ? .tertiary : .secondary)
                }
                .disabled(call.transcription == nil)
                .buttonStyle(.borderless)

                Button {
                    state.call(record: call)
                } label: {
                    Image(systemName: "phone")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var directionIcon: String {
        switch call.direction {
        case .incoming: return "phone.arrow.down.left"
        case .outgoing: return "phone.arrow.up.right"
        case .missed:   return "phone.badge.minus"
        }
    }

    private var directionColor: Color {
        switch call.direction {
        case .incoming: return .green
        case .outgoing: return .red
        case .missed:   return .red
        }
    }
}

private struct DialKeyButton: View {
    let number: String
    let letters: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(number)
                    .font(.headline.weight(.semibold))
                Text(letters)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 9)
            }
            .frame(width: 84, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CallAudioSettingsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionDevicePicker(
                title: "Speaker",
                kind: .speaker,
                levelTitle: "Call In",
                level: state.pjsipCallInputLevel,
                isPersistent: Binding(
                    get: { state.sessionSpeakerPersistent },
                    set: { state.setSessionAudioPersistent($0, kind: .speaker) }
                )
            )

            sessionDevicePicker(
                title: "Mikrofon",
                kind: .microphone,
                levelTitle: "Mic -> Bridge",
                level: state.pjsipMicrophoneInputLevel,
                isPersistent: Binding(
                    get: { state.sessionMicrophonePersistent },
                    set: { state.setSessionAudioPersistent($0, kind: .microphone) }
                )
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func sessionDevicePicker(
        title: String,
        kind: AudioRouteKind,
        levelTitle: String,
        level: Float,
        isPersistent: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
            Picker(
                title,
                selection: Binding(
                    get: { state.sessionAudioSelectionID(for: kind) },
                    set: { state.setSessionAudioDevice($0, kind: kind) }
                )
            ) {
                ForEach(state.devicesByKind[kind, default: []]) { device in
                    Text(device.displayLabel).tag(device.id)
                }
            }
            .pickerStyle(.menu)

            LevelMeterRow(title: levelTitle, level: level)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(kind == .speaker ? "Lautstärke" : "Empfindlichkeit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1fx", kind == .speaker ? state.sessionSpeakerVolume : state.sessionMicrophoneVolume))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { kind == .speaker ? Double(state.sessionSpeakerVolume) : Double(state.sessionMicrophoneVolume) },
                        set: { state.setSessionAudioVolume(Float($0), kind: kind) }
                    ),
                    in: 0 ... 2,
                    step: 0.1
                )
            }

            Toggle("Dieses Gerät dauerhaft priorisieren", isOn: isPersistent)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }
}

private struct ManagedCallCard: View {
    let title: String
    let call: ActiveCall
    let endTitle: String
    let isMicrophoneMuted: Bool
    let onToggleMute: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(stateLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(stateColor.opacity(0.18), in: Capsule())
            }

            Text(call.displayName)
                .font(.subheadline)
            Text(call.number)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button(isMicrophoneMuted ? "Unmute" : "Mute", action: onToggleMute)
                Button(endTitle, action: onEnd)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var stateLabel: String {
        switch call.state {
        case .connecting:
            return "verbinden"
        case .active:
            return "aktiv"
        case .onHold:
            return "wartend"
        case .conference:
            return "konferenz"
        }
    }

    private var stateColor: Color {
        switch call.state {
        case .connecting:
            return .orange
        case .active:
            return .green
        case .onHold:
            return .yellow
        case .conference:
            return .blue
        }
    }
}
