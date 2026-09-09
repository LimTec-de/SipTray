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
        .onAppear { state.refreshHomeEnvKeys() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshHomeEnvKeys()
        }
        .padding(12)
        .frame(width: 640, height: 740)
    }

    private var sipTab: some View {
        Form {
            Section("SIP") {
                if !state.settingsStorageError.isEmpty {
                    Text(state.settingsStorageError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
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

                    Button("Mikrofonfreigabe prüfen") {
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
                Button("Lizenzinformationen anzeigen") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses/THIRD_PARTY_NOTICES.md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(!FileManager.default.fileExists(atPath:
                    Bundle.main.resourceURL?.appendingPathComponent("Licenses/THIRD_PARTY_NOTICES.md").path ?? ""))
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

                Picker("Transkriptionsanbieter", selection: Binding(
                    get: { state.selectedTranscriptionProvider },
                    set: {
                        state.settings.transcriptionProvider = $0
                        if state.settings.transcriptionEnabled { state.checkPermissions() }
                    }
                )) {
                    ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if state.selectedTranscriptionProvider == .gemini {
                    TextField("Gemini-Modell-ID", text: $state.settings.geminiTranscriptionModel)
                    Text("Das Modell muss Audioeingaben und strukturierte JSON-Antworten der Interactions API unterstützen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if state.selectedTranscriptionProvider == .openai {
                    Picker("OpenAI-Modell", selection: $state.settings.openAITranscriptionModel) {
                        ForEach(TranscriptionProvider.openAIModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Text("gpt-4o-transcribe-diarize unterscheidet Sprecher. Whisper liefert Text mit Zeitmarken ohne Sprecherzuordnung.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("GEMINI_API_KEY aus ~/.env verwenden", isOn: Binding(
                    get: { state.settings.useGeminiAPIKeyFromHomeEnv },
                    set: { state.settings.useGeminiAPIKeyFromHomeEnv = $0 }
                ))
                .disabled(!state.homeEnvKeyNames.contains("GEMINI_API_KEY") && !state.settings.useGeminiAPIKeyFromHomeEnv)
                Text(state.homeEnvKeyNames.contains("GEMINI_API_KEY") ? "Gemini-Schlüssel gefunden" : "Kein Gemini-Schlüssel in ~/.env gefunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("OPENAI_API_KEY aus ~/.env verwenden", isOn: Binding(
                    get: { state.settings.useOpenAIKeyFromHomeEnv == true },
                    set: { state.settings.useOpenAIKeyFromHomeEnv = $0 }
                ))
                .disabled(!state.homeEnvKeyNames.contains("OPENAI_API_KEY") && state.settings.useOpenAIKeyFromHomeEnv != true)
                Text(state.homeEnvKeyNames.contains("OPENAI_API_KEY") ? "OpenAI-Schlüssel gefunden" : "Kein OpenAI-Schlüssel in ~/.env gefunden")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Gemini und OpenAI erhalten nach Gesprächsende das vollständige Gespräch mit beiden Seiten als eine gemeinsame Audiodatei. Es können API-Kosten entstehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Schlüssel neu prüfen") { state.refreshHomeEnvKeys() }
                    Button("Fehlende Transkripte erneut versuchen") { state.retryTranscriptions() }
                        .disabled(!state.settings.transcriptionEnabled)
                }
                Text(state.transcriptionStatus)
                    .font(.caption)
                    .textSelection(.enabled)

                Toggle("KI-Gesprächsprotokoll automatisch erstellen", isOn: $state.settings.automaticMinutes)
                Button("Fehlende Protokolle erstellen / erneut versuchen") { state.retryMissingMinutes() }
                Picker("Protokoll-Anbieter", selection: $state.settings.minutesProvider) {
                    Text("Wie Transkription (nur Cloud)").tag(Optional<TranscriptionProvider>.none)
                    Text("Gemini").tag(Optional(TranscriptionProvider.gemini))
                    Text("OpenAI").tag(Optional(TranscriptionProvider.openai))
                }
                if (state.settings.minutesProvider ?? state.selectedTranscriptionProvider) == .openai {
                    TextField("Protokoll-Textmodell", text: $state.settings.openAIMinutesModel)
                } else if (state.settings.minutesProvider ?? state.selectedTranscriptionProvider) == .gemini {
                    TextField("Protokoll-Textmodell", text: $state.settings.geminiMinutesModel)
                }
                Text("Das vollständige Transkript wird für das Protokoll zusätzlich an den gewählten Cloud-Anbieter gesendet. Es entstehen zusätzliche API-Kosten. Personen und Fristen bitte prüfen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Spracherkennung anfragen") {
                        state.requestSpeechRecognitionAccessIfNeeded()
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

                Button("Berechtigungen prüfen") {
                    state.checkPermissions()
                }
                Text("Der Assistent prüft Mikrofon und bei Apple-Transkription die Spracherkennung der Reihe nach. Bereits erteilte Freigaben werden übersprungen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Auf Updates prüfen") {
                    state.checkForUpdates()
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
