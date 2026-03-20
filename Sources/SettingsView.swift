import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            sipTab
                .tabItem {
                    Label("SIP", systemImage: "phone.connection")
                }

            audioTab
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }

            generalTab
                .tabItem {
                    Label("Allgemein", systemImage: "gearshape")
                }
        }
        .padding(12)
        .frame(width: 640, height: 740)
    }

    private var sipTab: some View {
        Form {
            Section("SIP") {
                HStack {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.connectionStatus.title)
                            .font(.subheadline.weight(.semibold))
                        Text(state.connectionStatus.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                TextField(
                    "VoIP Server",
                    text: Binding(
                        get: { state.settings.sip.server },
                        set: { newValue in
                            state.updateSIPSettings { settings in
                                settings.server = newValue
                            }
                        }
                    )
                )
                TextField(
                    "Anzeigename",
                    text: Binding(
                        get: { state.settings.sip.displayName },
                        set: { newValue in
                            state.updateSIPSettings { settings in
                                settings.displayName = newValue
                            }
                        }
                    )
                )
                TextField(
                    "SIP Benutzername",
                    text: Binding(
                        get: { state.settings.sip.username },
                        set: { newValue in
                            state.updateSIPSettings { settings in
                                settings.username = newValue
                            }
                        }
                    )
                )
                SecureField(
                    "Passwort",
                    text: Binding(
                        get: { state.settings.sip.password },
                        set: { newValue in
                            state.updateSIPSettings { settings in
                                settings.password = newValue
                            }
                        }
                    )
                )
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Section("Audio") {
                AudioSelectionSection(
                    title: "Ringtone",
                    kind: .ringtone,
                    selectedIDs: state.settings.audio.ringtoneDeviceIDs,
                    devices: state.devicesByKind[.ringtone, default: []],
                    toggle: { state.toggleDeviceSelection($0, kind: .ringtone) },
                    move: { state.moveDevice($0, by: $1, kind: .ringtone) }
                )
                AudioSelectionSection(
                    title: "Speaker",
                    kind: .speaker,
                    selectedIDs: state.settings.audio.speakerDeviceIDs,
                    devices: state.devicesByKind[.speaker, default: []],
                    toggle: { state.toggleDeviceSelection($0, kind: .speaker) },
                    move: { state.moveDevice($0, by: $1, kind: .speaker) }
                )
                AudioSelectionSection(
                    title: "Microphone",
                    kind: .microphone,
                    selectedIDs: state.settings.audio.microphoneDeviceIDs,
                    devices: state.devicesByKind[.microphone, default: []],
                    toggle: { state.toggleDeviceSelection($0, kind: .microphone) },
                    move: { state.moveDevice($0, by: $1, kind: .microphone) }
                )

                HStack {
                    Button("Neue Audiogeräte finden") {
                        state.discoverNewAudioDevices()
                    }

                    Button("Audiogeräte Reset") {
                        state.refreshAudioDevices()
                    }
                }

                HStack {
                    Button(state.isMicrophoneLoopbackRunning ? "Mikrofontest stoppen" : "Mikrofontest starten") {
                        state.toggleMicrophoneLoopback()
                    }

                    Button("Mikrofonfreigabe oeffnen") {
                        state.openMicrophonePrivacySettings()
                    }

                    Spacer()

                    Text(state.microphoneLoopbackStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                VStack(alignment: .leading, spacing: 8) {
                    LevelMeterRow(title: "Mic In", level: state.microphoneLoopbackInputLevel)
                    LevelMeterRow(title: "Loopback Out", level: state.microphoneLoopbackOutputLevel)
                    LevelMeterRow(title: "PJSIP Mic -> Bridge", level: state.pjsipMicrophoneInputLevel)
                    LevelMeterRow(title: "PJSIP Call In", level: state.pjsipCallInputLevel)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var generalTab: some View {
        Form {
            Section("Allgemein") {
                Toggle(
                    "Automatisch starten",
                    isOn: Binding(
                        get: { state.settings.launchAtLogin },
                        set: { state.setLaunchAtLogin($0) }
                    )
                )
                Toggle(
                    "Transcribe aktivieren",
                    isOn: Binding(
                        get: { state.settings.transcriptionEnabled },
                        set: { state.setTranscriptionEnabled($0) }
                    )
                )

                SecureField(
                    "Gemini API Key (optional)",
                    text: Binding(
                        get: { state.settings.geminiAPIKey },
                        set: { state.setGeminiAPIKey($0) }
                    )
                )

                TextField(
                    "Gemini Modell",
                    text: Binding(
                        get: { state.settings.geminiModelName },
                        set: { state.setGeminiModelName($0) }
                    )
                )

                Text("Wenn gesetzt, wird die lokale Transkription automatisch von Gemini sprachlich bereinigt und in einen Dialog umgewandelt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Spracherkennung anfragen") {
                        state.requestSpeechRecognitionAccessIfNeeded()
                    }

                    Button("Spracherkennung öffnen") {
                        state.openSpeechRecognitionPrivacySettings()
                    }

                    Spacer()

                    Text(state.speechRecognitionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("Als Standardanwendung für Telefonate registrieren") {
                        state.registerAsDefaultPhoneApp()
                    }

                    Spacer()

                    Text(state.isDefaultPhoneApp ? "Aktiv" : "Nicht aktiv")
                        .font(.caption)
                        .foregroundStyle(state.isDefaultPhoneApp ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Rufnummern-Umschreibung (Regexp)")
                        .font(.subheadline.weight(.semibold))

                    HStack {
                        TextField(
                            "Suchmuster",
                            text: Binding(
                                get: { state.settings.numberRewritePattern },
                                set: { state.setNumberRewritePattern($0) }
                            )
                        )
                        .frame(maxWidth: .infinity)

                        Text("→")
                            .foregroundStyle(.secondary)

                        TextField(
                            "Ersetzung",
                            text: Binding(
                                get: { state.settings.numberRewriteReplacement },
                                set: { state.setNumberRewriteReplacement($0) }
                            )
                        )
                        .frame(maxWidth: .infinity)
                    }

                    Text("Regulärer Ausdruck, der vor jedem Anruf auf die gewählte Nummer angewendet wird. Standard: führendes + durch 00 ersetzen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
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

struct LevelMeterRow: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.monospaced())
                .frame(width: 92, alignment: .leading)
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: max(4, proxy.size.width * CGFloat(level)))
                }
            }
            .frame(height: 10)

            Text("\(Int(level * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct AudioSelectionSection: View {
    let title: String
    let kind: AudioRouteKind
    let selectedIDs: [String]
    let devices: [HostAudioDevice]
    let toggle: (String) -> Void
    let move: (String, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text("Ausgewählte Reihenfolge: \(selectionSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !selectedDevices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(selectedDevices.enumerated()), id: \.element.id) { index, device in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.isOnline ? "online" : "offline")
                                    .font(.caption)
                                    .foregroundStyle(device.isOnline ? Color.secondary : Color.red)
                            }
                            Spacer()
                            Button {
                                move(device.id, -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .disabled(index == 0)

                            Button {
                                move(device.id, 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .disabled(index == selectedDevices.count - 1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(devices, id: \.id) { (device: HostAudioDevice) in
                HStack {
                    Toggle(
                        isOn: Binding(
                            get: { selectedIDs.contains(device.id) },
                            set: { _ in toggle(device.id) }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.isOnline ? "online" : "offline")
                                .font(.caption)
                                .foregroundStyle(device.isOnline ? Color.secondary : Color.red)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var selectionSummary: String {
        let names = selectedIDs.compactMap { id in
            devices.first(where: { $0.id == id })?.displayLabel
        }
        return names.isEmpty ? "Keine Auswahl" : names.joined(separator: " -> ")
    }

    private var selectedDevices: [HostAudioDevice] {
        selectedIDs.compactMap { id in
            devices.first(where: { $0.id == id })
        }
    }
}
