import AppKit
import AVFoundation
import Combine
import CoreServices
import Foundation
import Speech

private func transcribePreparedURLBackground(
    _ fileURL: URL?,
    enabled: Bool,
    service: CallTranscriptionService
) async -> String? {
    guard let fileURL else { return nil }
    return await withCheckedContinuation { continuation in
        service.transcribeIfNeeded(fileURL: fileURL, enabled: enabled) { text in
            continuation.resume(returning: text)
        }
    }
}

private func transcribePreparedSegmentsBackground(
    _ fileURL: URL?,
    speaker: CallTranscriptionService.TranscriptSpeaker,
    enabled: Bool,
    service: CallTranscriptionService
) async -> [CallTranscriptionService.TranscriptSegment]? {
    guard let fileURL else { return nil }
    return await withCheckedContinuation { continuation in
        service.transcribeSegmentsIfNeeded(fileURL: fileURL, speaker: speaker, enabled: enabled) { segments in
            continuation.resume(returning: segments)
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var dialedNumber = ""
    @Published var favorites: [Contact]
    @Published var recentCalls: [CallRecord]
    @Published var settings: AppSettings
    @Published var devicesByKind: [AudioRouteKind: [HostAudioDevice]] = [:]
    @Published var incomingCall: IncomingCall?
    @Published var isIncomingCallModalVisible = false
    @Published var isIncomingCallSilenced = false
    @Published var missedCallCount = 0
    @Published var connectionStatus: SIPConnectionStatus = .invalidConfiguration
    @Published var activeCall: ActiveCall?
    @Published var consultationCall: ActiveCall?
    @Published var isMicrophoneMuted = false
    @Published var selectedTranscriptCall: CallRecord?
    @Published var favoritePresenceByNumber: [String: FavoritePresenceState] = [:]
    @Published var isMicrophoneLoopbackRunning = false
    @Published var microphoneLoopbackStatus = "Mikrofonselbsttest aus"
    @Published var microphoneLoopbackInputLevel: Float = 0
    @Published var microphoneLoopbackOutputLevel: Float = 0
    @Published var pjsipMicrophoneInputLevel: Float = 0
    @Published var pjsipCallInputLevel: Float = 0
    @Published var sessionSpeakerDeviceID: String?
    @Published var sessionMicrophoneDeviceID: String?
    @Published var sessionSpeakerPersistent = false
    @Published var sessionMicrophonePersistent = false
    @Published var sessionSpeakerVolume: Float = 1.0
    @Published var sessionMicrophoneVolume: Float = 1.0
    @Published var speechRecognitionStatus = "Spracherkennung nicht geprüft"

    private let settingsStore: SettingsStore
    private let callHistoryStore: CallHistoryStore
    private let favoritesStore: FavoritesStore
    private let audioDeviceService: AudioDeviceService
    private let launchAtLoginService: LaunchAtLoginService
    private let transcriptionService: CallTranscriptionService
    private let geminiTranscriptPostProcessor = GeminiTranscriptPostProcessor()
    private let microphoneLoopbackService: MicrophoneLoopbackService
    private let sipService: SIPServiceProtocol
    private var cancellables: Set<AnyCancellable> = []
    private var callRecordIDsByActiveCallID: [UUID: UUID] = [:]
    private var pjsipLevelTask: Task<Void, Never>?
    private var audioDeviceMonitorTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        callHistoryStore: CallHistoryStore = CallHistoryStore(),
        favoritesStore: FavoritesStore = FavoritesStore(),
        audioDeviceService: AudioDeviceService = AudioDeviceService(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        transcriptionService: CallTranscriptionService? = nil,
        microphoneLoopbackService: MicrophoneLoopbackService = MicrophoneLoopbackService(),
        sipService: SIPServiceProtocol? = nil
    ) {
        self.settingsStore = settingsStore
        self.callHistoryStore = callHistoryStore
        self.favoritesStore = favoritesStore
        self.audioDeviceService = audioDeviceService
        self.launchAtLoginService = launchAtLoginService
        self.transcriptionService = transcriptionService ?? CallTranscriptionService()
        self.microphoneLoopbackService = microphoneLoopbackService
        self.sipService = sipService ?? PJSIPSIPService()
        let loadedSettings = settingsStore.load()
        let loadedRecentCalls = Self.trimmedRecentCalls(callHistoryStore.load())
        let loadedFavorites = favoritesStore.load()
        self.settings = loadedSettings
        self.recentCalls = Self.applyingFavorites(loadedFavorites, to: loadedRecentCalls)
        self.favorites = loadedFavorites
        self.microphoneLoopbackService.onLevelsChanged = { [weak self] inputLevel, outputLevel in
            guard let self else { return }
            if inputLevel >= 0 {
                self.microphoneLoopbackInputLevel = inputLevel
            }
            if outputLevel >= 0 {
                self.microphoneLoopbackOutputLevel = outputLevel
            }
        }

        self.sipService.delegate = self
        syncLaunchAtLoginSetting()
        bindPersistence()
        requestMicrophoneAccessIfNeeded()
        refreshAudioDevices()
        startAudioDeviceMonitoring()
        updateAudioConfiguration()
        self.sipService.configureTranscription(
            enabled: settings.transcriptionEnabled,
            recordingDirectory: self.transcriptionService.recordingsDirectoryURL
        )
        self.sipService.configure(settings: settings.sip)
        self.sipService.configureFavoritePresence(contacts: loadedFavorites)
        self.sipService.start()
        refreshSpeechRecognitionStatus()
        recoverPendingTranscriptions()
    }

    deinit {
        pjsipLevelTask?.cancel()
        audioDeviceMonitorTask?.cancel()
    }

    func input(_ value: String) {
        dialedNumber = Self.normalizedDialText(dialedNumber + value)
    }

    func backspace() {
        guard !dialedNumber.isEmpty else { return }
        dialedNumber.removeLast()
    }

    func clearDialedNumber() {
        dialedNumber = ""
    }

    func setDialedNumber(_ value: String) {
        dialedNumber = Self.normalizedDialText(value)
    }

    func placeCall() {
        let trimmed = dialedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let rewritten = applyNumberRewrite(trimmed)
        guard let newCall = sipService.placeCall(to: rewritten) else { return }
        resetSessionAudioLevels()
        activeCall = newCall
        consultationCall = nil
        let record = recentCallRecord(displayName: newCall.displayName, number: newCall.number, direction: .outgoing)
        recentCalls.insert(
            record,
            at: 0
        )
        callRecordIDsByActiveCallID[newCall.id] = record.id
        sipService.associateRecordingRecord(record.id, with: newCall.id)
        transcriptionService.startIfNeeded(for: newCall.id, enabled: settings.transcriptionEnabled)
        refreshPJSIPMeterPolling()
        clearDialedNumber()
    }

    func call(contact: Contact) {
        dialedNumber = contact.number
        placeCall()
    }

    func call(record: CallRecord) {
        dialedNumber = record.number
        placeCall()
    }

    func showTranscript(for record: CallRecord) {
        guard record.transcription?.isEmpty == false else { return }
        selectedTranscriptCall = record
    }

    func dismissTranscript() {
        selectedTranscriptCall = nil
    }

    var recentCallsLast7Days: [CallRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return recentCalls.filter { $0.date >= cutoff }
    }

    func toggleFavorite(for recordID: UUID) {
        guard let index = recentCalls.firstIndex(where: { $0.id == recordID }) else { return }
        recentCalls[index].isFavorite.toggle()
        let record = recentCalls[index]

        if record.isFavorite {
            upsertFavorite(Contact(name: record.displayName, number: record.number))
        } else {
            favorites.removeAll { $0.number == record.number }
        }
    }

    func addFavorite(name: String, number: String) {
        let trimmedNumber = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNumber.isEmpty else { return }

        let contact = Contact(
            name: trimmedName.isEmpty ? trimmedNumber : trimmedName,
            number: trimmedNumber
        )
        upsertFavorite(contact)
    }

    func removeFavorite(_ contactID: UUID) {
        guard let contact = favorites.first(where: { $0.id == contactID }) else { return }
        favorites.removeAll { $0.id == contactID }
        favoritePresenceByNumber.removeValue(forKey: contact.number)
        for index in recentCalls.indices where recentCalls[index].number == contact.number {
            recentCalls[index].isFavorite = false
        }
    }

    func updateSIPSettings(_ update: (inout SIPSettings) -> Void) {
        update(&settings.sip)
        sipService.configure(settings: settings.sip)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard settings.launchAtLogin != enabled else { return }
        settings.launchAtLogin = enabled
        launchAtLoginService.setEnabled(enabled)
    }

    func setTranscriptionEnabled(_ enabled: Bool) {
        guard settings.transcriptionEnabled != enabled else { return }
        settings.transcriptionEnabled = enabled
        if enabled {
            requestSpeechRecognitionAccessIfNeeded()
            recoverPendingTranscriptions()
        }
        sipService.configureTranscription(
            enabled: enabled,
            recordingDirectory: transcriptionService.recordingsDirectoryURL
        )
    }

    func setGeminiAPIKey(_ value: String) {
        settings.geminiAPIKey = value
    }

    func setGeminiModelName(_ value: String) {
        settings.geminiModelName = value
    }

    func setNumberRewritePattern(_ value: String) {
        settings.numberRewritePattern = value
    }

    func setNumberRewriteReplacement(_ value: String) {
        settings.numberRewriteReplacement = value
    }

    func applyNumberRewrite(_ number: String) -> String {
        let pattern = settings.numberRewritePattern
        let replacement = settings.numberRewriteReplacement
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern) else { return number }
        let range = NSRange(number.startIndex..., in: number)
        return regex.stringByReplacingMatches(in: number, range: range, withTemplate: replacement)
    }

    var isDefaultPhoneApp: Bool {
        guard let telURL = URL(string: "tel:0"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: telURL) else { return false }
        return appURL.standardized == Bundle.main.bundleURL.standardized
    }

    func shouldShowFavoritePresence(for contact: Contact) -> Bool {
        let trimmed = contact.number.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 6 && trimmed.allSatisfy(\.isNumber)
    }

    func favoritePresenceState(for contact: Contact) -> FavoritePresenceState {
        favoritePresenceByNumber[contact.number] ?? .checking
    }

    func registerAsDefaultPhoneApp() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("tel" as CFString, bundleID as CFString)
    }

    var connectionStatusColorName: String {
        switch connectionStatus {
        case .connected:
            return "green"
        case .connecting, .reconnecting:
            return "orange"
        case .networkUnavailable, .disconnected:
            return "red"
        case .invalidConfiguration:
            return "secondary"
        }
    }

    func toggleDeviceSelection(_ deviceID: String, kind: AudioRouteKind) {
        var ids = settings.audio.ids(for: kind)
        if let index = ids.firstIndex(of: deviceID) {
            ids.remove(at: index)
        } else {
            if deviceID == AudioDeviceService.systemDefaultID {
                ids.removeAll { $0 == deviceID }
                ids.append(deviceID)
            } else if let defaultIndex = ids.firstIndex(of: AudioDeviceService.systemDefaultID) {
                ids.insert(deviceID, at: defaultIndex)
            } else {
                ids.append(deviceID)
            }
        }

        let unique = Array(NSOrderedSet(array: ids).compactMap { $0 as? String })
        settings.audio.setIDs(unique, for: kind)
        updateAudioConfiguration()
    }

    func moveDeviceToFront(_ deviceID: String, kind: AudioRouteKind) {
        var ids = settings.audio.ids(for: kind)
        ids.removeAll { $0 == deviceID }
        ids.insert(deviceID, at: 0)
        settings.audio.setIDs(ids, for: kind)
        updateAudioConfiguration()
    }

    func moveDevice(_ deviceID: String, by offset: Int, kind: AudioRouteKind) {
        var ids = settings.audio.ids(for: kind)
        guard let currentIndex = ids.firstIndex(of: deviceID) else { return }

        let targetIndex = max(0, min(ids.count - 1, currentIndex + offset))
        guard targetIndex != currentIndex else { return }

        ids.remove(at: currentIndex)
        ids.insert(deviceID, at: targetIndex)
        settings.audio.setIDs(ids, for: kind)
        updateAudioConfiguration()
    }

    func resolvedDeviceLabel(for kind: AudioRouteKind) -> String {
        audioDeviceService.preferredDeviceName(
            for: kind,
            selectedIDs: settings.audio.ids(for: kind),
            devices: devicesByKind[kind, default: []]
        )
    }

    func refreshAudioDevices() {
        devicesByKind = ensureConfiguredDevicesPresent(
            discovered: audioDeviceService.loadDevices(),
            existing: devicesByKind
        )
        rememberKnownAudioDeviceNames()
        updateAudioConfiguration()
    }

    func discoverNewAudioDevices() {
        let discovered = audioDeviceService.loadDevices()
        devicesByKind = mergeDeviceCatalog(existing: devicesByKind, discovered: discovered)
        rememberKnownAudioDeviceNames()
        updateAudioConfiguration()
    }

    private func refreshAudioDeviceAvailability() {
        let discovered = audioDeviceService.loadDevices()
        let merged = ensureConfiguredDevicesPresent(
            discovered: mergeDeviceCatalog(existing: devicesByKind, discovered: discovered),
            existing: devicesByKind
        )
        guard merged != devicesByKind else { return }
        devicesByKind = merged
        rememberKnownAudioDeviceNames()
        updateAudioConfiguration()
    }

    func sessionAudioSelectionID(for kind: AudioRouteKind) -> String {
        switch kind {
        case .ringtone:
            return preferredConfiguredSelectionID(for: kind)
        case .speaker:
            return sessionSpeakerDeviceID ?? preferredConfiguredSelectionID(for: kind)
        case .microphone:
            return sessionMicrophoneDeviceID ?? preferredConfiguredSelectionID(for: kind)
        }
    }

    private func mergeDeviceCatalog(
        existing: [AudioRouteKind: [HostAudioDevice]],
        discovered: [AudioRouteKind: [HostAudioDevice]]
    ) -> [AudioRouteKind: [HostAudioDevice]] {
        var merged: [AudioRouteKind: [HostAudioDevice]] = [:]

        for kind in AudioRouteKind.allCases {
            let current = existing[kind, default: []]
            let latest = discovered[kind, default: []]
            let latestByID = Dictionary(uniqueKeysWithValues: latest.map { ($0.id, $0) })
            var unmatchedLatest = latest.filter { $0.id != AudioDeviceService.systemDefaultID }
            var combined: [HostAudioDevice] = []
            var seenIDs = Set<String>()

            for device in current {
                if let updated = latestByID[device.id] {
                    combined.append(updated)
                } else if device.id == AudioDeviceService.systemDefaultID {
                    combined.append(device)
                } else if let matchedIndex = unmatchedLatest.firstIndex(where: { candidate in
                    canRestoreExistingAudioDevice(existing: device, discovered: candidate)
                }) {
                    let matched = unmatchedLatest.remove(at: matchedIndex)
                    combined.append(
                        HostAudioDevice(
                            id: device.id,
                            coreAudioID: matched.coreAudioID,
                            name: matched.name,
                            isOnline: matched.isOnline,
                            kind: device.kind
                        )
                    )
                } else {
                    combined.append(
                        HostAudioDevice(
                            id: device.id,
                            coreAudioID: 0,
                            name: device.name,
                            isOnline: false,
                            kind: device.kind
                        )
                    )
                }
                seenIDs.insert(device.id)
            }

            for device in latest where !seenIDs.contains(device.id) && unmatchedLatest.contains(where: { $0.id == device.id }) {
                combined.append(device)
            }

            let defaultDevice = combined.first(where: { $0.id == AudioDeviceService.systemDefaultID })
            let others = combined
                .filter { $0.id != AudioDeviceService.systemDefaultID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            merged[kind] = (defaultDevice.map { [$0] } ?? []) + others
        }

        return merged
    }

    private func canRestoreExistingAudioDevice(existing: HostAudioDevice, discovered: HostAudioDevice) -> Bool {
        guard existing.kind == discovered.kind else { return false }
        guard existing.id != AudioDeviceService.systemDefaultID else { return false }
        guard discovered.id != AudioDeviceService.systemDefaultID else { return false }
        guard existing.id != discovered.id else { return false }
        guard !existing.isOnline else { return false }
        return normalizedAudioDeviceMatchKey(existing.name) == normalizedAudioDeviceMatchKey(discovered.name)
    }

    private func normalizedAudioDeviceMatchKey(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureConfiguredDevicesPresent(
        discovered: [AudioRouteKind: [HostAudioDevice]],
        existing: [AudioRouteKind: [HostAudioDevice]]
    ) -> [AudioRouteKind: [HostAudioDevice]] {
        var result = discovered

        for kind in AudioRouteKind.allCases {
            var devices = result[kind, default: []]
            let selectedIDs = settings.audio.ids(for: kind)

            for id in selectedIDs where id != AudioDeviceService.systemDefaultID {
                guard !devices.contains(where: { $0.id == id }) else { continue }
                let knownName =
                    existing[kind, default: []].first(where: { $0.id == id })?.name ??
                    settings.rememberedAudioDeviceNames[id] ??
                    "Audiogeraet \(id)"
                devices.append(
                    HostAudioDevice(
                        id: id,
                        coreAudioID: 0,
                        name: knownName,
                        isOnline: false,
                        kind: kind
                    )
                )
            }

            let defaultDevice = devices.first(where: { $0.id == AudioDeviceService.systemDefaultID })
            let others = devices
                .filter { $0.id != AudioDeviceService.systemDefaultID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            result[kind] = (defaultDevice.map { [$0] } ?? []) + others
        }

        return result
    }

    private func rememberKnownAudioDeviceNames() {
        var remembered = settings.rememberedAudioDeviceNames
        for devices in devicesByKind.values {
            for device in devices where device.id != AudioDeviceService.systemDefaultID {
                remembered[device.id] = device.name
            }
        }
        if remembered != settings.rememberedAudioDeviceNames {
            settings.rememberedAudioDeviceNames = remembered
        }
    }

    func setSessionAudioDevice(_ deviceID: String, kind: AudioRouteKind) {
        switch kind {
        case .ringtone:
            return
        case .speaker:
            sessionSpeakerDeviceID = deviceID
            if sessionSpeakerPersistent {
                prioritizeDevice(deviceID, for: .speaker)
            }
        case .microphone:
            sessionMicrophoneDeviceID = deviceID
            if sessionMicrophonePersistent {
                prioritizeDevice(deviceID, for: .microphone)
            }
        }
        updateAudioConfiguration()
    }

    func setSessionAudioPersistent(_ enabled: Bool, kind: AudioRouteKind) {
        switch kind {
        case .ringtone:
            return
        case .speaker:
            sessionSpeakerPersistent = enabled
            if enabled {
                prioritizeDevice(sessionAudioSelectionID(for: .speaker), for: .speaker)
            }
        case .microphone:
            sessionMicrophonePersistent = enabled
            if enabled {
                prioritizeDevice(sessionAudioSelectionID(for: .microphone), for: .microphone)
            }
        }
        updateAudioConfiguration()
    }

    func setSessionAudioVolume(_ value: Float, kind: AudioRouteKind) {
        switch kind {
        case .ringtone:
            return
        case .speaker:
            sessionSpeakerVolume = value
        case .microphone:
            sessionMicrophoneVolume = value
        }
        sipService.setSessionAudioLevels(
            microphone: sessionMicrophoneVolume,
            speaker: sessionSpeakerVolume
        )
    }

    func toggleMicrophoneLoopback() {
        if isMicrophoneLoopbackRunning {
            microphoneLoopbackService.stop()
            isMicrophoneLoopbackRunning = false
            microphoneLoopbackStatus = "Mikrofonselbsttest aus"
            microphoneLoopbackInputLevel = 0
            microphoneLoopbackOutputLevel = 0
            refreshAudioDevices()
            return
        }

        if #available(macOS 14.0, *) {
            let recordPermission = AVAudioApplication.shared.recordPermission
            if recordPermission == .undetermined {
                microphoneLoopbackStatus = "Bitte Mikrofonzugriff bestaetigen."
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.startMicrophoneLoopbackNow()
                        } else {
                            self.microphoneLoopbackStatus = "Mikrofonzugriff wurde nicht erlaubt. Bitte in Systemeinstellungen > Datenschutz > Mikrofon fuer SipTray aktivieren."
                            self.openMicrophonePrivacySettings()
                        }
                    }
                }
                return
            }
        }

        startMicrophoneLoopbackNow()
    }

    private func startMicrophoneLoopbackNow() {
        do {
            try microphoneLoopbackService.start(
                inputDeviceID: preferredHostDeviceID(for: .microphone),
                outputDeviceID: preferredHostDeviceID(for: .speaker)
            )
            isMicrophoneLoopbackRunning = true
            microphoneLoopbackStatus = "Loopback aktiv. Du solltest dich jetzt selbst hoeren."
            refreshAudioDevices()
        } catch {
            microphoneLoopbackService.stop()
            isMicrophoneLoopbackRunning = false
            microphoneLoopbackStatus = error.localizedDescription
            microphoneLoopbackInputLevel = 0
            microphoneLoopbackOutputLevel = 0
            refreshAudioDevices()
        }
    }

    func openMicrophonePrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSpeechRecognitionPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func requestSpeechRecognitionAccessIfNeeded() {
        let status = transcriptionService.authorizationStatus
        switch status {
        case .authorized:
            refreshSpeechRecognitionStatus()
        case .notDetermined:
            speechRecognitionStatus = "Bitte Spracherkennung bestätigen."
            transcriptionService.requestAuthorization { [weak self] _ in
                self?.refreshSpeechRecognitionStatus()
            }
        case .denied, .restricted:
            refreshSpeechRecognitionStatus()
            openSpeechRecognitionPrivacySettings()
        @unknown default:
            speechRecognitionStatus = "Spracherkennung unbekannt."
        }
    }

    func acceptIncomingCall() {
        guard let incomingCall else { return }
        guard let acceptedCall = sipService.accept(call: incomingCall) else { return }
        resetSessionAudioLevels()
        activeCall = acceptedCall
        consultationCall = nil
        let record = recentCallRecord(displayName: acceptedCall.displayName, number: acceptedCall.number, direction: .incoming)
        recentCalls.insert(
            record,
            at: 0
        )
        callRecordIDsByActiveCallID[acceptedCall.id] = record.id
        sipService.associateRecordingRecord(record.id, with: acceptedCall.id)
        transcriptionService.startIfNeeded(for: acceptedCall.id, enabled: settings.transcriptionEnabled)
        refreshPJSIPMeterPolling()
        self.incomingCall = nil
        isIncomingCallModalVisible = false
        isIncomingCallSilenced = false
    }

    func declineIncomingCall() {
        guard let incomingCall else { return }
        sipService.decline(call: incomingCall)
        self.incomingCall = nil
        isIncomingCallModalVisible = false
        isIncomingCallSilenced = false
    }

    func silenceIncomingCall() {
        guard let incomingCall else { return }
        sipService.silence(call: incomingCall)
        isIncomingCallModalVisible = false
        isIncomingCallSilenced = true
    }

    func markMissedCallIndicatorAsSeen() {
        missedCallCount = 0
    }

    func refreshPersistedCollections() {
        let loadedFavorites = favoritesStore.load()
        let loadedRecentCalls = Self.trimmedRecentCalls(callHistoryStore.load())
        favorites = loadedFavorites
        recentCalls = Self.applyingFavorites(loadedFavorites, to: loadedRecentCalls)
        recoverPendingTranscriptions()
    }

    func startConsultation() {
        guard let primaryCall = activeCall else { return }
        let trimmed = dialedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let newCall = sipService.beginConsultationCall(to: trimmed, from: primaryCall) else { return }
        resetSessionAudioLevels()
        activeCall?.state = .onHold
        consultationCall = newCall
        let record = recentCallRecord(displayName: newCall.displayName, number: newCall.number, direction: .outgoing)
        recentCalls.insert(
            record,
            at: 0
        )
        callRecordIDsByActiveCallID[newCall.id] = record.id
        sipService.associateRecordingRecord(record.id, with: newCall.id)
        transcriptionService.startIfNeeded(for: newCall.id, enabled: settings.transcriptionEnabled)
        refreshPJSIPMeterPolling()
        clearDialedNumber()
    }

    func transferActiveCall() {
        guard let primaryCall = activeCall, let consultationCall else { return }
        sipService.transfer(primaryCall: primaryCall, to: consultationCall)
        recentCalls.insert(
            CallRecord(
                displayName: "\(primaryCall.displayName) -> \(consultationCall.displayName)",
                number: consultationCall.number,
                direction: .outgoing
            ),
            at: 0
        )
        activeCall = nil
        self.consultationCall = nil
        refreshPJSIPMeterPolling()
    }

    func mergeConference() {
        guard let primaryCall = activeCall, let consultationCall else { return }
        sipService.mergeIntoConference(primaryCall: primaryCall, consultationCall: consultationCall)
        activeCall = ActiveCall(
            displayName: "\(primaryCall.displayName), \(consultationCall.displayName)",
            number: "\(primaryCall.number), \(consultationCall.number)",
            startedAt: min(primaryCall.startedAt, consultationCall.startedAt),
            state: .conference
        )
        self.consultationCall = nil
        refreshPJSIPMeterPolling()
    }

    func toggleMicrophoneMuted() {
        isMicrophoneMuted.toggle()
        sipService.setMicrophoneMuted(isMicrophoneMuted)
    }

    func end(_ role: ManagedCallRole) {
        switch role {
        case .primary:
            guard let activeCall else { return }
            sipService.end(call: activeCall)
            self.activeCall = consultationCall
            self.activeCall?.state = .active
            consultationCall = nil
        case .consultation:
            guard let consultationCall else { return }
            sipService.end(call: consultationCall)
            self.consultationCall = nil
            activeCall?.state = .active
        }

        if activeCall == nil, consultationCall == nil, isMicrophoneMuted {
            isMicrophoneMuted = false
            sipService.setMicrophoneMuted(false)
        }
        clearSessionAudioOverridesIfIdle()
        refreshPJSIPMeterPolling()
    }

    private func bindPersistence() {
        $settings
            .dropFirst()
            .sink { [weak self] settings in
                self?.settingsStore.save(settings)
            }
            .store(in: &cancellables)

        $recentCalls
            .dropFirst()
            .sink { [weak self] calls in
                guard let self else { return }
                let trimmed = Self.trimmedRecentCalls(calls)
                if trimmed != calls {
                    self.recentCalls = trimmed
                } else {
                    self.callHistoryStore.save(trimmed)
                }
            }
            .store(in: &cancellables)

        $favorites
            .dropFirst()
            .sink { [weak self] favorites in
                guard let self else { return }
                self.favoritesStore.save(favorites)
                self.sipService.configureFavoritePresence(contacts: favorites)
                let favoriteNumbers = Set(favorites.map(\.number))
                for index in self.recentCalls.indices {
                    self.recentCalls[index].isFavorite = favoriteNumbers.contains(self.recentCalls[index].number)
                }
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAudioDeviceAvailability()
            }
            .store(in: &cancellables)
    }

    private func syncLaunchAtLoginSetting() {
        settings.launchAtLogin = launchAtLoginService.isEnabled()
    }

    private func startAudioDeviceMonitoring() {
        audioDeviceMonitorTask?.cancel()
        audioDeviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshAudioDeviceAvailability()
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        }
    }

    private func preferredHostDeviceID(for kind: AudioRouteKind) -> String? {
        let selectedIDs = effectiveAudioSelection().ids(for: kind)
        let devices = devicesByKind[kind, default: []]

        for id in selectedIDs where id != AudioDeviceService.systemDefaultID {
            if devices.contains(where: { $0.id == id && $0.isOnline }) {
                return id
            }
        }

        return nil
    }

    private func requestMicrophoneAccessIfNeeded() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func refreshSpeechRecognitionStatus() {
        switch transcriptionService.authorizationStatus {
        case .authorized:
            speechRecognitionStatus = "Spracherkennung erlaubt"
        case .notDetermined:
            speechRecognitionStatus = "Spracherkennung noch nicht bestätigt"
        case .denied:
            speechRecognitionStatus = "Spracherkennung verweigert"
        case .restricted:
            speechRecognitionStatus = "Spracherkennung eingeschränkt"
        @unknown default:
            speechRecognitionStatus = "Spracherkennung unbekannt"
        }
    }

    private func recoverPendingTranscriptions() {
        guard settings.transcriptionEnabled else { return }
        for record in recentCallsLast7Days where record.transcription?.isEmpty != false {
            let recordID = record.id
            let service = transcriptionService
            let enabled = settings.transcriptionEnabled
            Task.detached { [weak self] in
                guard let self else { return }
                let shouldProceed = await MainActor.run { () -> Bool in
                    guard let index = self.recentCalls.firstIndex(where: { $0.id == recordID }) else { return false }
                    return self.recentCalls[index].transcription?.isEmpty != false
                }
                guard shouldProceed else { return }

                let localRawURL = service.recordingURL(for: recordID, speaker: .local)
                let remoteRawURL = service.recordingURL(for: recordID, speaker: .remote)
                let preparedLocalURL = FileManager.default.fileExists(atPath: localRawURL.path)
                    ? service.prepareRecordingFile(localRawURL)
                    : nil
                let preparedRemoteURL = FileManager.default.fileExists(atPath: remoteRawURL.path)
                    ? service.prepareRecordingFile(remoteRawURL)
                    : nil

                let localText = await transcribePreparedURLBackground(preparedLocalURL, enabled: enabled, service: service)
                let remoteText = await transcribePreparedURLBackground(preparedRemoteURL, enabled: enabled, service: service)
                guard let merged = service.mergeTranscript(local: localText, remote: remoteText) else { return }
                let processed = await self.postProcessedTranscriptIfNeeded(rawTranscript: merged, recordID: recordID) ?? merged

                service.cleanupRecordingArtifacts(
                    rawFileURLs: [localRawURL, remoteRawURL],
                    preparedFileURLs: [preparedLocalURL, preparedRemoteURL]
                )

                await MainActor.run {
                    guard let latestIndex = self.recentCalls.firstIndex(where: { $0.id == recordID }) else { return }
                    self.recentCalls[latestIndex].transcription = processed
                }
            }
        }
    }

    private func updateAudioConfiguration() {
        sipService.configureAudio(selection: effectiveAudioSelection(), deviceCatalog: devicesByKind)
        sipService.setSessionAudioLevels(
            microphone: sessionMicrophoneVolume,
            speaker: sessionSpeakerVolume
        )
    }

    private func effectiveAudioSelection() -> AudioRouteSelection {
        var selection = settings.audio
        guard activeCall != nil || consultationCall != nil else {
            return selection
        }

        if let sessionSpeakerDeviceID {
            selection.speakerDeviceIDs = prioritizedIDs(sessionSpeakerDeviceID, existing: selection.speakerDeviceIDs)
        }
        if let sessionMicrophoneDeviceID {
            selection.microphoneDeviceIDs = prioritizedIDs(sessionMicrophoneDeviceID, existing: selection.microphoneDeviceIDs)
        }
        return selection
    }

    private func prioritizedIDs(_ prioritizedID: String, existing: [String]) -> [String] {
        var ids = existing.filter { $0 != prioritizedID }
        ids.insert(prioritizedID, at: 0)
        let unique = Array(NSOrderedSet(array: ids).compactMap { $0 as? String })
        return unique.isEmpty ? [AudioDeviceService.systemDefaultID] : unique
    }

    private func prioritizeDevice(_ deviceID: String, for kind: AudioRouteKind) {
        settings.audio.setIDs(prioritizedIDs(deviceID, existing: settings.audio.ids(for: kind)), for: kind)
    }

    private func preferredConfiguredSelectionID(for kind: AudioRouteKind) -> String {
        let selectedIDs = settings.audio.ids(for: kind)
        let devices = devicesByKind[kind, default: []]

        for id in selectedIDs where id != AudioDeviceService.systemDefaultID {
            if devices.contains(where: { $0.id == id && $0.isOnline }) {
                return id
            }
        }

        if selectedIDs.contains(AudioDeviceService.systemDefaultID) {
            return AudioDeviceService.systemDefaultID
        }

        return devices.first?.id ?? AudioDeviceService.systemDefaultID
    }

    private func clearSessionAudioOverridesIfIdle() {
        guard activeCall == nil, consultationCall == nil else { return }
        sessionSpeakerDeviceID = nil
        sessionMicrophoneDeviceID = nil
        sessionSpeakerPersistent = false
        sessionMicrophonePersistent = false
        resetSessionAudioLevels()
        updateAudioConfiguration()
    }

    private func resetSessionAudioLevels() {
        sessionSpeakerVolume = 1.0
        sessionMicrophoneVolume = 1.0
        sipService.setSessionAudioLevels(
            microphone: sessionMicrophoneVolume,
            speaker: sessionSpeakerVolume
        )
    }

    private func finalizeTranscription(for activeCallID: UUID) {
        guard callRecordIDsByActiveCallID[activeCallID] != nil else { return }
        guard settings.transcriptionEnabled else {
            callRecordIDsByActiveCallID.removeValue(forKey: activeCallID)
            return
        }

        transcriptionService.stopIfNeeded(for: activeCallID, enabled: settings.transcriptionEnabled) { [weak self] text in
            guard let self, let text, let recordID = self.callRecordIDsByActiveCallID.removeValue(forKey: activeCallID) else { return }
            Task { @MainActor in
                guard let index = self.recentCalls.firstIndex(where: { $0.id == recordID }) else { return }
                self.recentCalls[index].transcription = text
            }
        }
    }

    private static func trimmedRecentCalls(_ calls: [CallRecord]) -> [CallRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return calls
            .map { sanitizeRecentCallRecord($0) }
            .filter { $0.date >= cutoff }
            .sorted { $0.date > $1.date }
    }

    private static func applyingFavorites(_ favorites: [Contact], to calls: [CallRecord]) -> [CallRecord] {
        let favoriteNumbers = Set(favorites.map(\.number))
        return calls.map { call in
            var updated = call
            updated.isFavorite = favoriteNumbers.contains(call.number)
            return updated
        }
    }

    private static func normalizedDialText(_ value: String) -> String {
        let mapping: [Character: Character] = [
            "A": "2", "B": "2", "C": "2",
            "D": "3", "E": "3", "F": "3",
            "G": "4", "H": "4", "I": "4",
            "J": "5", "K": "5", "L": "5",
            "M": "6", "N": "6", "O": "6",
            "P": "7", "Q": "7", "R": "7", "S": "7",
            "T": "8", "U": "8", "V": "8",
            "W": "9", "X": "9", "Y": "9", "Z": "9"
        ]

        var result = ""
        for scalar in value.uppercased() {
            if let mapped = mapping[scalar] {
                result.append(mapped)
            } else if scalar.isNumber || scalar == "+" || scalar == "*" || scalar == "#" {
                result.append(scalar)
            }
        }
        return result
    }

    private func recentCallRecord(displayName: String, number: String, direction: CallRecord.Direction) -> CallRecord {
        Self.sanitizeRecentCallRecord(
            CallRecord(displayName: displayName, number: number, direction: direction)
        )
    }

    private static func sanitizeRecentCallRecord(_ record: CallRecord) -> CallRecord {
        var sanitized = record
        sanitized.displayName = sanitized.preferredDisplayName
        sanitized.number = sanitized.number.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized
    }

    private func upsertFavorite(_ contact: Contact) {
        if let index = favorites.firstIndex(where: { $0.number == contact.number }) {
            favorites[index].name = contact.name
        } else {
            favorites.insert(contact, at: 0)
        }

        for index in recentCalls.indices where recentCalls[index].number == contact.number {
            recentCalls[index].isFavorite = true
        }
    }

    private func refreshPJSIPMeterPolling() {
        pjsipLevelTask?.cancel()
        pjsipLevelTask = nil
        pjsipMicrophoneInputLevel = 0
        pjsipCallInputLevel = 0

        guard let pjsipService = sipService as? PJSIPSIPService else { return }
        guard activeCall != nil || consultationCall != nil else { return }

        pjsipLevelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let levels = pjsipService.currentSignalLevels()
                self.pjsipMicrophoneInputLevel = levels.microphoneInput
                self.pjsipCallInputLevel = levels.callInput
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}

enum ManagedCallRole {
    case primary
    case consultation
}

@MainActor
extension AppState: SIPServiceDelegate {
    func sipService(_ service: SIPServiceProtocol, didChangeConnectionStatus status: SIPConnectionStatus) {
        connectionStatus = status
    }

    func sipService(_ service: SIPServiceProtocol, didUpdateCall call: ActiveCall) {
        if activeCall?.id == call.id {
            activeCall = call
        } else if consultationCall?.id == call.id {
            consultationCall = call
        }
        refreshPJSIPMeterPolling()
    }

    func sipService(_ service: SIPServiceProtocol, didUpdateFavoritePresence number: String, state: FavoritePresenceState) {
        _ = service
        favoritePresenceByNumber[number] = state
    }

    func sipService(_ service: SIPServiceProtocol, didEndCall activeCallID: UUID) {
        finalizeTranscription(for: activeCallID)
        if activeCall?.id == activeCallID {
            activeCall = consultationCall
            activeCall?.state = .active
            consultationCall = nil
        } else if consultationCall?.id == activeCallID {
            consultationCall = nil
            activeCall?.state = .active
        }

        if activeCall == nil, consultationCall == nil, isMicrophoneMuted {
            isMicrophoneMuted = false
            sipService.setMicrophoneMuted(false)
        }
        refreshPJSIPMeterPolling()
    }

    func sipService(
        _ service: SIPServiceProtocol,
        didFinishCallRecording activeCallID: UUID,
        localSegments: [CallTranscriptionService.TranscriptSegment]?,
        localFileURL: URL?,
        remoteFileURL: URL?
    ) {
        _ = service
        guard let recordID = resolveTranscriptionRecordID(for: activeCallID) else { return }
        let service = transcriptionService
        let enabled = settings.transcriptionEnabled
        Task.detached { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 500_000_000)

            let preparedLocalURL = localFileURL.flatMap { service.prepareRecordingFile($0) }
            let preparedRemoteURL = remoteFileURL.flatMap { service.prepareRecordingFile($0) }
            let localOnsetOffset = preparedLocalURL.map { service.audioOnsetOffset(for: $0) } ?? 0
            let remoteOnsetOffset = preparedRemoteURL.map { service.audioOnsetOffset(for: $0) } ?? 0

            let localPreparedSegments = await transcribePreparedSegmentsBackground(
                preparedLocalURL,
                speaker: .local,
                enabled: enabled,
                service: service
            ) ?? []
            let remoteSegments = await transcribePreparedSegmentsBackground(
                preparedRemoteURL,
                speaker: .remote,
                enabled: enabled,
                service: service
            ) ?? []
            let shiftedLocalSegments = (localSegments ?? localPreparedSegments).map {
                CallTranscriptionService.TranscriptSegment(
                    speaker: $0.speaker,
                    timestamp: $0.timestamp + localOnsetOffset,
                    duration: $0.duration,
                    text: $0.text
                )
            }
            let shiftedRemoteSegments = remoteSegments.map {
                CallTranscriptionService.TranscriptSegment(
                    speaker: $0.speaker,
                    timestamp: $0.timestamp + remoteOnsetOffset,
                    duration: $0.duration,
                    text: $0.text
                )
            }
            guard let merged = service.mergeSegments(local: shiftedLocalSegments, remote: shiftedRemoteSegments) else { return }
            let processed = await self.postProcessedTranscriptIfNeeded(rawTranscript: merged, recordID: recordID) ?? merged

            service.cleanupRecordingArtifacts(
                rawFileURLs: [localFileURL, remoteFileURL],
                preparedFileURLs: [preparedLocalURL, preparedRemoteURL]
            )

            await MainActor.run {
                guard let index = self.recentCalls.firstIndex(where: { $0.id == recordID }) else { return }
                self.recentCalls[index].transcription = processed
            }
        }
    }

    private func resolveTranscriptionRecordID(for activeCallID: UUID) -> UUID? {
        if let recordID = callRecordIDsByActiveCallID.removeValue(forKey: activeCallID) {
            return recordID
        }

        let cutoff = Date().addingTimeInterval(-15 * 60)
        return recentCalls.first(where: { $0.transcription == nil && $0.date >= cutoff })?.id
    }

    private func postProcessedTranscriptIfNeeded(rawTranscript: String, recordID: UUID) async -> String? {
        let apiKey = settings.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = settings.geminiModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        let context = await MainActor.run { () -> (direction: CallRecord.Direction, date: Date, remoteName: String, remoteNumber: String)? in
            guard let record = recentCalls.first(where: { $0.id == recordID }) else { return nil }
            return (record.direction, record.date, record.displayName, record.number)
        }
        guard let context else { return nil }

        let localParticipant = TranscriptParticipant(
            name: settings.sip.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? settings.sip.username
                : settings.sip.displayName,
            number: settings.sip.username
        )
        let remoteParticipant = TranscriptParticipant(
            name: context.remoteName,
            number: context.remoteNumber
        )

        let caller: TranscriptParticipant
        let callee: TranscriptParticipant
        switch context.direction {
        case .outgoing:
            caller = localParticipant
            callee = remoteParticipant
        case .incoming, .missed:
            caller = remoteParticipant
            callee = localParticipant
        }

        return await geminiTranscriptPostProcessor.process(
            transcript: rawTranscript,
            apiKey: apiKey,
            modelName: modelName,
            callDate: context.date,
            caller: caller,
            callee: callee
        )
    }

    func sipService(_ service: SIPServiceProtocol, didReceiveIncomingCall call: IncomingCall) {
        incomingCall = call
        isIncomingCallModalVisible = true
        isIncomingCallSilenced = false
    }

    func sipService(_ service: SIPServiceProtocol, didMissCall call: IncomingCall) {
        guard incomingCall?.id == call.id else { return }
        incomingCall = nil
        isIncomingCallModalVisible = false
        isIncomingCallSilenced = false
        missedCallCount += 1
        recentCalls.insert(
            recentCallRecord(displayName: call.displayName, number: call.number, direction: .missed),
            at: 0
        )
    }
}
