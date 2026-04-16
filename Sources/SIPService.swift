import Foundation
import Network
import CPJSIP
import AVFoundation

@MainActor
protocol SIPServiceDelegate: AnyObject {
    func sipService(_ service: SIPServiceProtocol, didChangeConnectionStatus status: SIPConnectionStatus)
    func sipService(_ service: SIPServiceProtocol, didReceiveIncomingCall call: IncomingCall)
    func sipService(_ service: SIPServiceProtocol, didMissCall call: IncomingCall)
    func sipService(_ service: SIPServiceProtocol, didUpdateCall call: ActiveCall)
    func sipService(_ service: SIPServiceProtocol, didEndCall activeCallID: UUID)
    func sipService(
        _ service: SIPServiceProtocol,
        didFinishCallRecording activeCallID: UUID,
        localSegments: [CallTranscriptionService.TranscriptSegment]?,
        localFileURL: URL?,
        remoteFileURL: URL?
    )
    func sipService(_ service: SIPServiceProtocol, didUpdateFavoritePresence number: String, state: FavoritePresenceState)
}

@MainActor
protocol SIPServiceProtocol: AnyObject {
    var delegate: SIPServiceDelegate? { get set }
    func configure(settings: SIPSettings)
    func configureAudio(selection: AudioRouteSelection, deviceCatalog: [AudioRouteKind: [HostAudioDevice]])
    func configureTranscription(enabled: Bool, recordingDirectory: URL?)
    func associateRecordingRecord(_ recordID: UUID, with activeCallID: UUID)
    func start()
    func placeCall(to number: String) -> ActiveCall?
    func beginConsultationCall(to number: String, from activeCall: ActiveCall) -> ActiveCall?
    func transfer(primaryCall: ActiveCall, to consultationCall: ActiveCall)
    func mergeIntoConference(primaryCall: ActiveCall, consultationCall: ActiveCall)
    func end(call: ActiveCall)
    func accept(call: IncomingCall) -> ActiveCall?
    func decline(call: IncomingCall)
    func silence(call: IncomingCall)
    func setMicrophoneMuted(_ muted: Bool)
    func setSessionAudioLevels(microphone: Float, speaker: Float)
    func configureFavoritePresence(contacts: [Contact])
}

private struct PJSIPAudioDevice {
    let id: Int32
    let name: String
    let driver: String
    let inputCount: UInt32
    let outputCount: UInt32
}

private struct PendingOutgoingCallAttempt {
    let originalNumber: String
    let attemptedDestinations: [String]
    let remainingDestinations: [String]
    let hadMedia: Bool
}

private struct CallRecordingState {
    let callID: Int32
    let localRecorderID: Int32?
    let localFileURL: URL?
    let remoteRecorderID: Int32?
    let remoteFileURL: URL?
}

private struct PJSIPBuddyInfo {
    let id: Int32
    let status: Int32
    let subscriptionState: Int32
    let uri: String
    let statusText: String
}

private final class PJSIPServiceBox {
    weak var service: PJSIPSIPService?
}

private let globalPJSIPService = PJSIPServiceBox()
private let spInvalidID = Int32(SP_INVALID_ID)
private let spTransportUDP = Int32(SP_TRANSPORT_UDP)
private let spTransportTCP = Int32(SP_TRANSPORT_TCP)
private let spCallStateDisconnected = Int32(SP_CALL_STATE_DISCONNECTED)
private let spCallStateConnecting = Int32(SP_CALL_STATE_CONNECTING)
private let spCallStateIncoming = Int32(SP_CALL_STATE_INCOMING)
private let spCallStateEarly = Int32(SP_CALL_STATE_EARLY)
private let spCallStateConfirmed = Int32(SP_CALL_STATE_CONFIRMED)
private let spMediaStatusActive = Int32(SP_MEDIA_STATUS_ACTIVE)
private let spMediaStatusLocalHold = Int32(SP_MEDIA_STATUS_LOCAL_HOLD)
private let spMediaStatusRemoteHold = Int32(SP_MEDIA_STATUS_REMOTE_HOLD)
private let spSpeakerOnlyMode = UInt32(1)

private func onIncomingCall(accID: Int32, callID: Int32) {
    Task { @MainActor in
        globalPJSIPService.service?.handleIncomingCall(accID: accID, callID: callID)
    }
}

private func onCallState(callID: Int32) {
    Task { @MainActor in
        globalPJSIPService.service?.handleCallStateChanged(callID: callID)
    }
}

private func onCallMediaState(callID: Int32) {
    Task { @MainActor in
        globalPJSIPService.service?.handleCallMediaState(callID: callID)
    }
}

private func onRegistrationState(accID: Int32) {
    Task { @MainActor in
        globalPJSIPService.service?.handleRegistrationStateChanged(accID: accID)
    }
}

private func onBuddyState(buddyID: Int32) {
    Task { @MainActor in
        globalPJSIPService.service?.handleBuddyStateChanged(buddyID: buddyID)
    }
}

@MainActor
final class PJSIPSIPService: SIPServiceProtocol {
    weak var delegate: SIPServiceDelegate?

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "de.limtec.siptray.network")
    private let diagnostics = DiagnosticsLogger()
    private let systemAudioRouteController = SystemAudioRouteController()

    private var settings = SIPSettings()
    private var audioSelection = AudioRouteSelection()
    private var systemDeviceCatalog: [AudioRouteKind: [HostAudioDevice]] = [:]
    private var currentStatus: SIPConnectionStatus = .invalidConfiguration
    private var hasSatisfiedNetwork = true
    private var didReceiveInitialNetworkPathEvent = false
    private var lastNetworkPathSignature = ""
    private var isStarted = false
    private var didInitializePJSIP = false

    private var udpTransportID: Int32 = spInvalidID
    private var tcpTransportID: Int32 = spInvalidID
    private var registeredAccountID: Int32?

    private var incomingCallsByUUID: [UUID: Int32] = [:]
    private var activeCallsByUUID: [UUID: Int32] = [:]
    private var callIDToIncomingUUID: [Int32: UUID] = [:]
    private var callIDToActiveUUID: [Int32: UUID] = [:]
    private var incomingCallSnapshotByUUID: [UUID: IncomingCall] = [:]
    private var handledIncomingCallIDs: Set<Int32> = []
    private var silencedIncomingCallIDs: Set<Int32> = []
    private var ringtonePlayerID: Int32 = spInvalidID
    private var ringtoneRestartTask: Task<Void, Never>?
    private var ringtoneFileURL: URL?
    private var ringbackPlayerID: Int32 = spInvalidID
    private var ringbackRestartTask: Task<Void, Never>?
    private var ringbackFileURL: URL?
    private var isMicrophoneMuted = false
    private var sessionMicrophoneVolume: Float = 1.0
    private var sessionSpeakerVolume: Float = 1.0
    private var pendingOutgoingAttempts: [UUID: PendingOutgoingCallAttempt] = [:]
    private var transcriptionEnabled = false
    private var transcriptionDirectoryURL: URL?
    private var currentExtraCaptureDeviceID: Int32?
    private var callRecordingsByActiveUUID: [UUID: CallRecordingState] = [:]
    private var recordingRecordIDsByActiveUUID: [UUID: UUID] = [:]
    private var monitoredFavoriteContacts: [String: Contact] = [:]
    private var buddyIDsByNumber: [String: Int32] = [:]
    private var buddyNumbersByID: [Int32: String] = [:]
    deinit {
        diagnostics.log("service deinit")
        ringtoneRestartTask?.cancel()
        ringbackRestartTask?.cancel()
        monitor.cancel()
        systemAudioRouteController.restoreIfNeeded()
        if didInitializePJSIP {
            sipphone_pj_register_thread_if_needed("siptray")
            if ringtonePlayerID != spInvalidID {
                _ = sp_pjsip_destroy_player(ringtonePlayerID)
            }
            if ringbackPlayerID != spInvalidID {
                _ = sp_pjsip_destroy_player(ringbackPlayerID)
            }
            sp_pjsip_destroy()
        }
    }

    func configure(settings: SIPSettings) {
        self.settings = settings
        diagnostics.log("configure SIP server=\(settings.server) user=\(settings.username)")
        updateRegistration()
    }

    func configureAudio(selection: AudioRouteSelection, deviceCatalog: [AudioRouteKind: [HostAudioDevice]]) {
        audioSelection = selection
        systemDeviceCatalog = deviceCatalog
        diagnostics.log("configure audio ringtone=\(selection.ringtoneDeviceIDs) speaker=\(selection.speakerDeviceIDs) microphone=\(selection.microphoneDeviceIDs)")
        restorePreferredAudioRouting()
    }

    func configureTranscription(enabled: Bool, recordingDirectory: URL?) {
        transcriptionEnabled = enabled
        transcriptionDirectoryURL = recordingDirectory
    }

    func associateRecordingRecord(_ recordID: UUID, with activeCallID: UUID) {
        recordingRecordIDsByActiveUUID[activeCallID] = recordID
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        globalPJSIPService.service = self
        diagnostics.resetSession()
        diagnostics.log("service start")

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPath(path)
            }
        }
        monitor.start(queue: monitorQueue)

        guard initializePJSIP() else { return }
        updateRegistration()
    }

    func placeCall(to number: String) -> ActiveCall? {
        guard settings.isComplete else {
            publishStatus(.invalidConfiguration)
            return nil
        }
        guard hasSatisfiedNetwork else {
            publishStatus(.networkUnavailable)
            return nil
        }
        guard registeredAccountID != nil else {
            publishStatus(.disconnected(reason: "Kein SIP-Account registriert"))
            return nil
        }
        guard currentStatus == .connected else {
            publishStatus(.disconnected(reason: "SIP-Registrierung noch nicht abgeschlossen"))
            return nil
        }

        if normalizedDialTarget(number) == normalizedDialTarget(settings.username) {
            diagnostics.log("place call warning: destination matches own SIP username")
        }

        let call = ActiveCall(displayName: number, number: number, state: .connecting)
        let destinations = destinationURIs(for: number)
        guard !destinations.isEmpty else {
            return nil
        }

        guard attemptOutgoingCall(
            for: call.id,
            originalNumber: number,
            remainingDestinations: destinations,
            attemptedDestinations: []
        ) else {
            return nil
        }
        return call
    }

    func beginConsultationCall(to number: String, from activeCall: ActiveCall) -> ActiveCall? {
        guard let primaryCallID = activeCallsByUUID[activeCall.id] else { return nil }
        _ = sp_pjsip_hold(primaryCallID)
        return placeCall(to: number)
    }

    func transfer(primaryCall: ActiveCall, to consultationCall: ActiveCall) {
        guard
            let primaryCallID = activeCallsByUUID[primaryCall.id],
            let consultationCallID = activeCallsByUUID[consultationCall.id]
        else { return }
        _ = sp_pjsip_transfer_replaces(primaryCallID, consultationCallID)
    }

    func mergeIntoConference(primaryCall: ActiveCall, consultationCall: ActiveCall) {
        guard
            let primaryCallID = activeCallsByUUID[primaryCall.id],
            let consultationCallID = activeCallsByUUID[consultationCall.id]
        else { return }
        _ = sp_pjsip_conference_connect(primaryCallID, consultationCallID)
    }

    func end(call: ActiveCall) {
        guard let callID = activeCallsByUUID[call.id] else { return }
        _ = sp_pjsip_hangup(callID, 0)
    }

    func accept(call: IncomingCall) -> ActiveCall? {
        guard let callID = incomingCallsByUUID[call.id] else { return nil }
        handledIncomingCallIDs.insert(callID)
        silencedIncomingCallIDs.remove(callID)
        stopRingtone()
        applyActiveAudioRouting()

        guard sp_pjsip_answer(callID, 200) == 0 else { return nil }
        unregisterIncomingCall(callID: callID)
        let activeCall = registerActiveCall(callID: callID, fallbackNumber: call.number, fallbackState: .active)
        _ = sp_pjsip_attach_audio(callID)
        scheduleDeferredAudioRoutingRefresh()
        applyMicrophoneMuteState()
        return activeCall
    }

    func decline(call: IncomingCall) {
        guard let callID = incomingCallsByUUID[call.id] else { return }
        handledIncomingCallIDs.insert(callID)
        silencedIncomingCallIDs.remove(callID)
        stopRingtone()
        _ = sp_pjsip_hangup(callID, 603)
    }

    func silence(call: IncomingCall) {
        guard let callID = incomingCallsByUUID[call.id] else { return }
        silencedIncomingCallIDs.insert(callID)
        stopRingtone()
        _ = sp_pjsip_set_null_sound_device()
    }

    func setMicrophoneMuted(_ muted: Bool) {
        isMicrophoneMuted = muted
        applyMicrophoneMuteState()
    }

    func setSessionAudioLevels(microphone: Float, speaker: Float) {
        sessionMicrophoneVolume = max(0, min(microphone, 2.0))
        sessionSpeakerVolume = max(0, min(speaker, 2.0))
        applySessionAudioLevels()
    }

    func configureFavoritePresence(contacts: [Contact]) {
        monitoredFavoriteContacts = Dictionary(
            uniqueKeysWithValues: contacts.compactMap { contact in
                guard canMonitorPresence(for: contact.number) else { return nil }
                return (contact.number, contact)
            }
        )
        syncFavoritePresenceSubscriptions()
    }

    func currentSignalLevels() -> (microphoneInput: Float, callInput: Float) {
        guard didInitializePJSIP else { return (0, 0) }

        var micTX: UInt32 = 0
        var micRX: UInt32 = 0
        _ = sp_pjsip_get_capture_signal_levels(&micTX, &micRX)

        var callTX: UInt32 = 0
        var callRX: UInt32 = 0
        if let callID = activeCallsByUUID.values.first {
            _ = sp_pjsip_get_call_signal_levels(callID, &callTX, &callRX)
        }

        return (
            microphoneInput: min(Float(micRX) / 255.0, 1),
            callInput: min(Float(callRX) / 255.0, 1)
        )
    }

    func handleIncomingCall(accID: Int32, callID: Int32) {
        _ = accID
        diagnostics.log("incoming call id=\(callID)")
        let incoming = registerIncomingCall(callID: callID)
        if shouldPlayRingtone(for: callID) {
            applyRingingAudioRouting()
            startRingtone()
        }
        delegate?.sipService(self, didReceiveIncomingCall: incoming)
    }

    func handleCallStateChanged(callID: Int32) {
        guard let info = callInfo(for: callID) else {
            diagnostics.log("call state id=\(callID) without call info")
            handleDisconnectedCallWithoutInfo(callID: callID)
            return
        }
        diagnostics.log("call state id=\(callID) state=\(info.state) media=\(info.mediaStatus) last=\(info.lastStatus) text=\(info.lastStatusText)")

        if info.state == spCallStateDisconnected {
            if let incomingUUID = callIDToIncomingUUID[callID] {
                let incoming = incomingCall(for: incomingUUID, info: info)
                unregisterIncomingCall(callID: callID)
                let wasHandled = handledIncomingCallIDs.remove(callID) != nil
                silencedIncomingCallIDs.remove(callID)
                if incomingCallsByUUID.isEmpty {
                    stopRingtone()
                }
                if !wasHandled {
                    delegate?.sipService(self, didMissCall: incoming)
                }
            }

            if let activeUUID = callIDToActiveUUID[callID] {
                if retryOutgoingCallIfNeeded(activeUUID: activeUUID, failedCallID: callID, info: info) {
                    return
                }
                finishRecordingIfNeeded(for: activeUUID)
                if info.state == spCallStateDisconnected,
                   info.lastStatus >= 300,
                   info.mediaStatus != spMediaStatusActive {
                    let detail = info.lastStatusText.isEmpty ? "SIP \(info.lastStatus)" : info.lastStatusText
                    publishStatus(.disconnected(reason: "Anruf fehlgeschlagen: \(detail)"))
                }
                pendingOutgoingAttempts.removeValue(forKey: activeUUID)
                unregisterActiveCall(callID: callID)
                delegate?.sipService(self, didEndCall: activeUUID)
            }

            restorePreferredAudioRouting()
        } else if info.mediaStatus == spMediaStatusActive {
            if let activeUUID = callIDToActiveUUID[callID], let pending = pendingOutgoingAttempts[activeUUID] {
                pendingOutgoingAttempts[activeUUID] = PendingOutgoingCallAttempt(
                    originalNumber: pending.originalNumber,
                    attemptedDestinations: pending.attemptedDestinations,
                    remainingDestinations: pending.remainingDestinations,
                    hadMedia: true
                )
            }
            applyMicrophoneMuteState()
        }

        publishUpdatedCall(callID: callID, info: info)
    }

    func handleCallMediaState(callID: Int32) {
        guard let info = callInfo(for: callID) else { return }
        diagnostics.log("call media state id=\(callID) state=\(info.state) media=\(info.mediaStatus)")
        guard info.mediaStatus == spMediaStatusActive || info.mediaStatus == spMediaStatusRemoteHold else {
            return
        }

        if let activeUUID = callIDToActiveUUID[callID], let pending = pendingOutgoingAttempts[activeUUID] {
            pendingOutgoingAttempts[activeUUID] = PendingOutgoingCallAttempt(
                originalNumber: pending.originalNumber,
                attemptedDestinations: pending.attemptedDestinations,
                remainingDestinations: pending.remainingDestinations,
                hadMedia: true
            )
        }

        applyActiveAudioRouting()
        _ = sp_pjsip_attach_audio(callID)
        applyActiveAudioRouting()
        scheduleDeferredAudioRoutingRefresh()
        applyMicrophoneMuteState()
        if let activeUUID = callIDToActiveUUID[callID] {
            startRecordingIfNeeded(for: activeUUID, callID: callID)
        }
        publishUpdatedCall(callID: callID, info: info)
    }

    func handleRegistrationStateChanged(accID: Int32) {
        guard let registeredAccountID, registeredAccountID == accID else { return }
        var info = sp_account_info()
        guard sp_pjsip_get_account_info(accID, &info) == 0 else {
            publishStatus(.disconnected(reason: "Registrierungsstatus unbekannt"))
            return
        }
        diagnostics.log("registration state acc=\(accID) status=\(info.status) text=\(cString(from: info.status_text))")

        switch Int(info.status) {
        case 0, 100..<200:
            publishStatus(.connecting)
        case 200..<300:
            publishStatus(.connected)
            syncFavoritePresenceSubscriptions()
        default:
            let detail = cString(from: info.status_text)
            publishStatus(.disconnected(reason: detail.isEmpty ? "Registrierung fehlgeschlagen" : detail))
        }
    }

    func handleBuddyStateChanged(buddyID: Int32) {
        guard let number = buddyNumbersByID[buddyID] else { return }
        delegate?.sipService(self, didUpdateFavoritePresence: number, state: favoritePresenceState(for: buddyID))
    }

    private func initializePJSIP() -> Bool {
        var callbacks = sp_callbacks(
            on_incoming_call: onIncomingCall,
            on_call_state: onCallState,
            on_call_media_state: onCallMediaState,
            on_registration_state: onRegistrationState,
            on_buddy_state: onBuddyState
        )

        guard sp_pjsip_create(&callbacks) == 0 else {
            publishStatus(.disconnected(reason: "PJSIP-Initialisierung fehlgeschlagen"))
            return false
        }
        diagnostics.log("pjsip initialized")

        guard createTransports() else { return false }
        diagnostics.log("transports udp=\(udpTransportID) tcp=\(tcpTransportID)")
        guard sp_pjsip_start() == 0 else {
            publishStatus(.disconnected(reason: "PJSIP-Start fehlgeschlagen"))
            return false
        }

        didInitializePJSIP = true
        restorePreferredAudioRouting()
        return true
    }

    private func createTransports() -> Bool {
        udpTransportID = spInvalidID
        tcpTransportID = spInvalidID

        if sp_pjsip_create_transport(spTransportUDP, 5060, &udpTransportID) != 0 &&
            sp_pjsip_create_transport(spTransportUDP, 0, &udpTransportID) != 0 {
            publishStatus(.disconnected(reason: "UDP-Transport konnte nicht erstellt werden"))
            return false
        }

        if sp_pjsip_create_transport(spTransportTCP, 5060, &tcpTransportID) != 0 {
            _ = sp_pjsip_create_transport(spTransportTCP, 0, &tcpTransportID)
        }

        return true
    }

    private func handleNetworkPath(_ path: NWPath) {
        let isSatisfied = path.status == .satisfied
        let signature = networkPathSignature(path)
        let previousSatisfied = hasSatisfiedNetwork
        let previousSignature = lastNetworkPathSignature

        hasSatisfiedNetwork = isSatisfied
        lastNetworkPathSignature = signature

        guard isStarted else { return }
        guard hasSatisfiedNetwork else {
            publishStatus(.networkUnavailable)
            return
        }

        if !didReceiveInitialNetworkPathEvent {
            didReceiveInitialNetworkPathEvent = true
            diagnostics.log("network path initial satisfied=\(isSatisfied) signature=\(signature)")
            return
        }

        guard !previousSatisfied || previousSignature != signature else {
            diagnostics.log("network path unchanged, skipping reconnect signature=\(signature)")
            return
        }

        if settings.isComplete {
            publishStatus(.reconnecting)
            diagnostics.log("network path changed, reconnect old=\(previousSignature) new=\(signature)")
            _ = sp_pjsip_handle_ip_change()
            if let registeredAccountID {
                _ = sp_pjsip_set_registration(registeredAccountID, 1)
            }
            updateRegistration()
        } else {
            publishStatus(.invalidConfiguration)
        }
    }

    private func updateRegistration() {
        guard isStarted, didInitializePJSIP else {
            publishStatus(settings.isComplete ? .connecting : .invalidConfiguration)
            return
        }
        guard hasSatisfiedNetwork else {
            publishStatus(.networkUnavailable)
            return
        }
        guard settings.isComplete else {
            clearRegisteredAccount()
            publishStatus(.invalidConfiguration)
            return
        }

        clearRegisteredAccount()
        if addRegisteredAccount() {
            publishStatus(currentStatus == .connected ? .connected : .connecting)
        } else {
            publishStatus(.disconnected(reason: "Registrierung fehlgeschlagen"))
        }
    }

    private func addRegisteredAccount() -> Bool {
        let transportID = preferredTransportID()
        var accountID = spInvalidID
        let status = identityURI().withCString { identity in
            registrarURI().withCString { registrar in
                settings.username.withCString { username in
                    settings.password.withCString { password in
                        sp_pjsip_add_account(identity, registrar, username, password, transportID, &accountID)
                    }
                }
            }
        }
        guard status == 0 else { return false }
        registeredAccountID = accountID
        diagnostics.log("registered account added acc=\(accountID) transport=\(transportID) registrar=\(registrarURI()) identity=\(identityURI())")
        return true
    }

    private func clearRegisteredAccount() {
        guard let registeredAccountID else { return }
        _ = sp_pjsip_set_registration(registeredAccountID, 0)
        _ = sp_pjsip_delete_account(registeredAccountID)
        self.registeredAccountID = nil
    }

    private func publishStatus(_ status: SIPConnectionStatus) {
        currentStatus = status
        diagnostics.log("status -> \(status.title) detail=\(status.detail)")
        delegate?.sipService(self, didChangeConnectionStatus: status)
    }

    private func identityURI() -> String {
        let bareURI = "sip:\(settings.username)@\(identityDomain())"
        let displayName = settings.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return bareURI }
        let escapedName = displayName.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedName)\" <\(bareURI)>"
    }

    private func registrarURI() -> String {
        let trimmed = settings.server.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("sip:") || trimmed.hasPrefix("sips:") {
            return trimmed
        }
        return "sip:\(trimmed)"
    }

    private func identityDomain() -> String {
        let trimmed = settings.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutScheme = trimmed
            .replacingOccurrences(of: "sip:", with: "")
            .replacingOccurrences(of: "sips:", with: "")
        return withoutScheme.split(separator: ";", maxSplits: 1).first.map(String.init) ?? withoutScheme
    }

    private func destinationURI(for input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") || trimmed.hasPrefix("sip:") || trimmed.hasPrefix("sips:") {
            return trimmed.hasPrefix("sip:") || trimmed.hasPrefix("sips:") ? trimmed : "sip:\(trimmed)"
        }
        return "sip:\(trimmed)@\(identityDomain())"
    }

    private func destinationURIs(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("sip:") || trimmed.hasPrefix("sips:") || trimmed.contains("@") {
            return [destinationURI(for: trimmed)]
        }

        var variants: [String] = []
        let withDomain = "sip:\(trimmed)@\(identityDomain())"
        variants.append(withDomain)
        variants.append("\(withDomain);user=phone")
        variants.append("sip:\(trimmed)")
        variants.append("sip:\(trimmed);user=phone")

        let digitsOnly = trimmed.filter { $0.isNumber || $0 == "+" || $0 == "*" || $0 == "#" }
        if digitsOnly == trimmed {
            variants.append("tel:\(trimmed)")
        }

        return Array(NSOrderedSet(array: variants).compactMap { $0 as? String })
    }

    private func preferredTransportID() -> Int32 {
        let server = settings.server.lowercased()
        if server.contains("transport=tcp"), tcpTransportID != spInvalidID {
            return tcpTransportID
        }
        if server.contains("transport=udp"), udpTransportID != spInvalidID {
            return udpTransportID
        }
        return spInvalidID
    }

    private func registerIncomingCall(callID: Int32) -> IncomingCall {
        if let existingUUID = callIDToIncomingUUID[callID], let info = callInfo(for: callID) {
            let incoming = incomingCall(for: existingUUID, info: info)
            incomingCallSnapshotByUUID[existingUUID] = incoming
            return incoming
        }

        let parsed = parseRemoteIdentity(from: callInfo(for: callID)?.remoteInfo ?? "")
        let incoming = IncomingCall(id: UUID(), displayName: parsed.displayName, number: parsed.number)
        incomingCallsByUUID[incoming.id] = callID
        callIDToIncomingUUID[callID] = incoming.id
        incomingCallSnapshotByUUID[incoming.id] = incoming
        return incoming
    }

    private func unregisterIncomingCall(callID: Int32) {
        if let uuid = callIDToIncomingUUID.removeValue(forKey: callID) {
            incomingCallsByUUID.removeValue(forKey: uuid)
            incomingCallSnapshotByUUID.removeValue(forKey: uuid)
        }
    }

    private func registerActiveCall(callID: Int32, fallbackNumber: String, fallbackState: ActiveCall.State) -> ActiveCall {
        if let existingUUID = callIDToActiveUUID[callID], let info = callInfo(for: callID), let active = activeCall(for: existingUUID, info: info) {
            return active
        }

        let parsed = parseRemoteIdentity(from: callInfo(for: callID)?.remoteInfo ?? "")
        let active = ActiveCall(
            id: UUID(),
            displayName: parsed.displayName.isEmpty ? fallbackNumber : parsed.displayName,
            number: parsed.number.isEmpty ? fallbackNumber : parsed.number,
            state: fallbackState
        )
        activeCallsByUUID[active.id] = callID
        callIDToActiveUUID[callID] = active.id
        return active
    }

    private func registerActiveCall(
        callID: Int32,
        activeUUID: UUID,
        fallbackNumber: String,
        fallbackState: ActiveCall.State
    ) -> ActiveCall {
        if let info = callInfo(for: callID), let active = activeCall(for: activeUUID, info: info) {
            activeCallsByUUID[activeUUID] = callID
            callIDToActiveUUID[callID] = activeUUID
            return active
        }

        let parsed = parseRemoteIdentity(from: callInfo(for: callID)?.remoteInfo ?? "")
        let active = ActiveCall(
            id: activeUUID,
            displayName: parsed.displayName.isEmpty ? fallbackNumber : parsed.displayName,
            number: parsed.number.isEmpty ? fallbackNumber : parsed.number,
            state: fallbackState
        )
        activeCallsByUUID[active.id] = callID
        callIDToActiveUUID[callID] = active.id
        return active
    }

    private func unregisterActiveCall(callID: Int32) {
        if let uuid = callIDToActiveUUID.removeValue(forKey: callID) {
            activeCallsByUUID.removeValue(forKey: uuid)
        }
    }

    private func handleDisconnectedCallWithoutInfo(callID: Int32) {
        var didChangeTrackedCalls = false

        if let incomingUUID = callIDToIncomingUUID[callID] {
            let cachedIncoming = incomingCallSnapshotByUUID[incomingUUID]
            unregisterIncomingCall(callID: callID)
            let wasHandled = handledIncomingCallIDs.remove(callID) != nil
            silencedIncomingCallIDs.remove(callID)
            if incomingCallsByUUID.isEmpty {
                stopRingtone()
            }
            if !wasHandled {
                let incoming = cachedIncoming ?? IncomingCall(id: incomingUUID, displayName: "Unbekannt", number: "")
                delegate?.sipService(self, didMissCall: incoming)
            }
            didChangeTrackedCalls = true
        }

        if let activeUUID = callIDToActiveUUID[callID] {
            pendingOutgoingAttempts.removeValue(forKey: activeUUID)
            unregisterActiveCall(callID: callID)
            delegate?.sipService(self, didEndCall: activeUUID)
            didChangeTrackedCalls = true
        }

        if didChangeTrackedCalls {
            restorePreferredAudioRouting()
        }
    }

    private func publishUpdatedCall(callID: Int32, info: WrappedCallInfo) {
        guard
            let activeUUID = callIDToActiveUUID[callID],
            let active = activeCall(for: activeUUID, info: info)
        else { return }
        delegate?.sipService(self, didUpdateCall: active)
    }

    private func incomingCall(for id: UUID, info: WrappedCallInfo) -> IncomingCall {
        let parsed = parseRemoteIdentity(from: info.remoteInfo)
        let incoming = IncomingCall(id: id, displayName: parsed.displayName, number: parsed.number)
        incomingCallSnapshotByUUID[id] = incoming
        return incoming
    }

    private func activeCall(for id: UUID, info: WrappedCallInfo) -> ActiveCall? {
        guard activeCallsByUUID[id] != nil else { return nil }
        let parsed = parseRemoteIdentity(from: info.remoteInfo)
        let state: ActiveCall.State = {
            switch (info.state, info.mediaStatus) {
            case (_, spMediaStatusLocalHold), (_, spMediaStatusRemoteHold):
                return .onHold
            case (spCallStateConfirmed, _), (_, spMediaStatusActive):
                return .active
            case (spCallStateConnecting, _), (spCallStateIncoming, _), (spCallStateEarly, _):
                return .connecting
            default:
                return .connecting
            }
        }()
        return ActiveCall(id: id, displayName: parsed.displayName, number: parsed.number, state: state)
    }

    private func callInfo(for callID: Int32) -> WrappedCallInfo? {
        var info = sp_call_info()
        guard sp_pjsip_get_call_info(callID, &info) == 0 else { return nil }
        return WrappedCallInfo(
            state: info.state,
            mediaStatus: info.media_status,
            remoteInfo: cString(from: info.remote_info),
            lastStatus: info.last_status,
            lastStatusText: cString(from: info.last_status_text)
        )
    }

    private func restorePreferredAudioRouting() {
        guard didInitializePJSIP else { return }
        diagnostics.log("restore audio routing activeCalls=\(activeCallsByUUID.count) incomingCalls=\(incomingCallsByUUID.count)")
        if hasAudibleIncomingCalls {
            stopRingback()
            applyRingingAudioRouting()
            startRingtone()
        } else if hasOutgoingRingbackCalls {
            stopRingtone()
            applyRingbackAudioRouting()
            startRingback()
        } else if !activeCallsByUUID.isEmpty {
            stopRingtone()
            stopRingback()
            applyActiveAudioRouting()
        } else {
            stopRingtone()
            stopRingback()
            applyIdleAudioRouting()
        }
    }

    private func startRingtone() {
        guard ringtoneRestartTask == nil else { return }

        let playCycle: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard self.hasAudibleIncomingCalls else {
                self.stopRingtone()
                return
            }

            self.applyRingingAudioRouting()
            self.stopCurrentRingtonePlayback()
            guard let path = self.ensureRingtoneFile()?.path else { return }

            var playerID = spInvalidID
            if path.withCString({ sp_pjsip_play_wav_file($0, &playerID) }) == 0 {
                self.ringtonePlayerID = playerID
                self.applyRingingAudioRouting()
            }
        }

        playCycle()
        ringtoneRestartTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                playCycle()
            }
        }
    }

    private func stopRingtone() {
        ringtoneRestartTask?.cancel()
        ringtoneRestartTask = nil
        stopCurrentRingtonePlayback()
    }

    private func stopCurrentRingtonePlayback() {
        guard ringtonePlayerID != spInvalidID else { return }
        _ = sp_pjsip_destroy_player(ringtonePlayerID)
        ringtonePlayerID = spInvalidID
    }

    private func startRingback() {
        guard ringbackRestartTask == nil else { return }

        let playCycle: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            guard self.hasOutgoingRingbackCalls else {
                self.stopRingback()
                return
            }

            self.applyRingbackAudioRouting()
            self.stopCurrentRingbackPlayback()
            guard let path = self.ensureRingbackFile()?.path else { return }

            var playerID = spInvalidID
            if path.withCString({ sp_pjsip_play_wav_file($0, &playerID) }) == 0 {
                self.ringbackPlayerID = playerID
                self.applyRingbackAudioRouting()
            }
        }

        playCycle()
        ringbackRestartTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_400_000_000)
                playCycle()
            }
        }
    }

    private func stopRingback() {
        ringbackRestartTask?.cancel()
        ringbackRestartTask = nil
        stopCurrentRingbackPlayback()
    }

    private func stopCurrentRingbackPlayback() {
        guard ringbackPlayerID != spInvalidID else { return }
        _ = sp_pjsip_destroy_player(ringbackPlayerID)
        ringbackPlayerID = spInvalidID
    }

    private var hasAudibleIncomingCalls: Bool {
        incomingCallsByUUID.values.contains { !silencedIncomingCallIDs.contains($0) }
    }

    private var hasOutgoingRingbackCalls: Bool {
        activeCallsByUUID.values.contains { callID in
            guard let info = callInfo(for: callID) else { return false }
            return info.mediaStatus != spMediaStatusActive &&
                (info.state == spCallStateConnecting || info.state == spCallStateEarly)
        }
    }

    private func shouldPlayRingtone(for callID: Int32) -> Bool {
        !silencedIncomingCallIDs.contains(callID)
    }

    private func ensureRingtoneFile() -> URL? {
        if let ringtoneFileURL {
            return ringtoneFileURL
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("siptray-ringtone.wav")
        do {
            try makeRingtoneWaveData().write(to: url, options: .atomic)
            ringtoneFileURL = url
            return url
        } catch {
            return nil
        }
    }

    private func ensureRingbackFile() -> URL? {
        if let ringbackFileURL {
            return ringbackFileURL
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("siptray-ringback.wav")
        do {
            try makeRingbackWaveData().write(to: url, options: .atomic)
            ringbackFileURL = url
            return url
        } catch {
            return nil
        }
    }

    private func applyRingingAudioRouting() {
        _ = sp_pjsip_clear_extra_capture_device()
        currentExtraCaptureDeviceID = nil
        applySystemAudioFallback(inputHostID: nil, outputHostID: preferredHostDeviceID(for: .ringtone))
        applyPlayback(
            capture: nil,
            playback: preferredOutputDeviceID(for: .ringtone),
            mode: spSpeakerOnlyMode
        )
    }

    private func applyRingbackAudioRouting() {
        _ = sp_pjsip_clear_extra_capture_device()
        currentExtraCaptureDeviceID = nil
        applySystemAudioFallback(inputHostID: nil, outputHostID: preferredHostDeviceID(for: .speaker))
        applyPlayback(
            capture: nil,
            playback: preferredOutputDeviceID(for: .speaker),
            mode: spSpeakerOnlyMode
        )
    }

    private func applyActiveAudioRouting() {
        applySystemAudioFallback(
            inputHostID: preferredHostDeviceID(for: .microphone),
            outputHostID: preferredHostDeviceID(for: .speaker)
        )
        let preferredCapture = preferredInputDeviceID() ?? spInvalidID
        if currentExtraCaptureDeviceID != preferredCapture {
            _ = sp_pjsip_set_extra_capture_device(preferredCapture)
            currentExtraCaptureDeviceID = preferredCapture
        }
        applyPlayback(
            capture: nil,
            playback: preferredOutputDeviceID(for: .speaker),
            mode: spSpeakerOnlyMode
        )
        reattachActiveCallAudio()
        applySessionAudioLevels()
        applyMicrophoneMuteState()
    }

    private func applyIdleAudioRouting() {
        _ = sp_pjsip_clear_extra_capture_device()
        currentExtraCaptureDeviceID = nil
        systemAudioRouteController.restoreIfNeeded()

        if currentStatus == .connected {
            diagnostics.log("audio -> idle speaker-only prewarm")
            applySystemAudioFallback(inputHostID: nil, outputHostID: preferredHostDeviceID(for: .speaker))
            applyPlayback(
                capture: nil,
                playback: preferredOutputDeviceID(for: .speaker),
                mode: spSpeakerOnlyMode
            )
        } else {
            _ = sp_pjsip_set_null_sound_device()
            diagnostics.log("audio -> null sound device")
        }
    }

    private func scheduleDeferredAudioRoutingRefresh() {
        guard didInitializePJSIP else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.applyActiveAudioRouting()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            self?.applyActiveAudioRouting()
        }
    }

    private func applyMicrophoneMuteState() {
        guard didInitializePJSIP, !activeCallsByUUID.isEmpty else { return }
        if isMicrophoneMuted {
            _ = sp_pjsip_set_microphone_muted(1)
        } else {
            _ = sp_pjsip_set_microphone_volume(sessionMicrophoneVolume)
        }
    }

    private func reattachActiveCallAudio() {
        guard didInitializePJSIP else { return }
        for callID in activeCallsByUUID.values {
            _ = sp_pjsip_attach_audio(callID)
        }
    }

    private func applySessionAudioLevels() {
        guard didInitializePJSIP, !activeCallsByUUID.isEmpty else { return }
        if !isMicrophoneMuted {
            _ = sp_pjsip_set_microphone_volume(sessionMicrophoneVolume)
        }
        for callID in activeCallsByUUID.values {
            _ = sp_pjsip_set_speaker_volume(callID, sessionSpeakerVolume)
        }
    }

    private func applyPlayback(capture: Int32?, playback: Int32?, mode: UInt32) {
        guard didInitializePJSIP else { return }
        let requestedCapture = capture ?? spInvalidID
        let requestedPlayback = playback ?? spInvalidID
        let status: Int32
        if mode == 0 {
            status = sp_pjsip_set_sound_devices(requestedCapture, requestedPlayback)
        } else {
            status = sp_pjsip_set_sound_devices_with_mode(requestedCapture, requestedPlayback, mode)
        }

        guard status == 0 else {
            publishStatus(.disconnected(reason: "Audio-Routing fehlgeschlagen: \(pjsipStatusText(for: status))"))
            return
        }

        var actualCapture = Int32(0)
        var actualPlayback = Int32(0)
        let getStatus = sp_pjsip_get_sound_devices(&actualCapture, &actualPlayback)
        diagnostics.log(
            "audio route mode=\(mode) requested capture=\(requestedCapture) playback=\(requestedPlayback) " +
            "actualStatus=\(getStatus) actual capture=\(actualCapture) playback=\(actualPlayback) " +
            "requestedCaptureName=\(deviceDescription(forPJSIPID: requestedCapture, kind: .microphone)) " +
            "requestedPlaybackName=\(deviceDescription(forPJSIPID: requestedPlayback, kind: mode == spSpeakerOnlyMode ? .ringtone : .speaker)) " +
            "actualCaptureName=\(deviceDescription(forPJSIPID: actualCapture, kind: .microphone)) " +
            "actualPlaybackName=\(deviceDescription(forPJSIPID: actualPlayback, kind: mode == spSpeakerOnlyMode ? .ringtone : .speaker))"
        )
    }

    private func preferredInputDeviceID() -> Int32? {
        resolvePJSIPDeviceID(for: .microphone)
    }

    private func preferredOutputDeviceID(for kind: AudioRouteKind) -> Int32? {
        resolvePJSIPDeviceID(for: kind)
    }

    private func preferredHostDeviceID(for kind: AudioRouteKind) -> String? {
        let selectedIDs = audioSelection.ids(for: kind)
        let hostDevices = systemDeviceCatalog[kind, default: []]

        for id in selectedIDs where id != AudioDeviceService.systemDefaultID {
            if let device = hostDevices.first(where: { $0.id == id && $0.isOnline }) {
                return String(device.coreAudioID)
            }
        }

        return nil
    }

    private func resolvePJSIPDeviceID(for kind: AudioRouteKind) -> Int32? {
        let selectedIDs = audioSelection.ids(for: kind)
        let hostDevices = systemDeviceCatalog[kind, default: []]
        let pjsipDevices = availablePJSIPAudioDevices()

        for id in selectedIDs where id != AudioDeviceService.systemDefaultID {
            guard let hostDevice = hostDevices.first(where: { $0.id == id && $0.isOnline }) else { continue }

            if let match = matchPJSIPDevice(for: hostDevice, kind: kind, in: pjsipDevices) {
                diagnostics.log("resolved \(kind.rawValue) host=\(hostDevice.name)#\(hostDevice.id) -> pjsip=\(match.name)#\(match.id)")
                return match.id
            }
            diagnostics.log("failed resolve \(kind.rawValue) host=\(hostDevice.name)#\(hostDevice.id)")
        }

        if selectedIDs.contains(AudioDeviceService.systemDefaultID) {
            diagnostics.log("resolved \(kind.rawValue) -> system default fallback")
        }
        return nil
    }

    private func applySystemAudioFallback(inputHostID: String?, outputHostID: String?) {
        systemAudioRouteController.apply(inputDeviceID: inputHostID, outputDeviceID: outputHostID)
        diagnostics.log("host audio fallback input=\(inputHostID ?? "system-default") output=\(outputHostID ?? "system-default")")
    }

    private func syncFavoritePresenceSubscriptions() {
        let desiredNumbers = Set(monitoredFavoriteContacts.keys)
        let currentNumbers = Set(buddyIDsByNumber.keys)

        for removedNumber in currentNumbers.subtracting(desiredNumbers) {
            if let buddyID = buddyIDsByNumber.removeValue(forKey: removedNumber) {
                buddyNumbersByID.removeValue(forKey: buddyID)
                _ = sp_pjsip_delete_buddy(buddyID)
            }
            delegate?.sipService(self, didUpdateFavoritePresence: removedNumber, state: .unknown)
        }

        guard currentStatus == .connected, let accountID = registeredAccountID else {
            for number in desiredNumbers {
                delegate?.sipService(self, didUpdateFavoritePresence: number, state: .checking)
            }
            return
        }

        for number in desiredNumbers where buddyIDsByNumber[number] == nil {
            guard let uri = buddyURI(for: number) else { continue }
            var buddyID = spInvalidID
            let status = sp_pjsip_add_buddy(uri, accountID, &buddyID)
            guard status == 0, buddyID != spInvalidID else {
                delegate?.sipService(self, didUpdateFavoritePresence: number, state: .unknown)
                continue
            }
            buddyIDsByNumber[number] = buddyID
            buddyNumbersByID[buddyID] = number
            delegate?.sipService(self, didUpdateFavoritePresence: number, state: .checking)
            delegate?.sipService(self, didUpdateFavoritePresence: number, state: favoritePresenceState(for: buddyID))
        }
    }

    private func buddyURI(for number: String) -> String? {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = settings.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canMonitorPresence(for: trimmed), !domain.isEmpty else { return nil }
        return "sip:\(trimmed)@\(domain)"
    }

    private func canMonitorPresence(for number: String) -> Bool {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 6 else { return false }
        return trimmed.allSatisfy(\.isNumber)
    }

    private func favoritePresenceState(for buddyID: Int32) -> FavoritePresenceState {
        guard let info = buddyInfo(for: buddyID) else { return .unknown }
        switch info.status {
        case 1:
            return .online
        case 2:
            return .offline
        default:
            return .checking
        }
    }

    private func buddyInfo(for buddyID: Int32) -> PJSIPBuddyInfo? {
        var info = sp_buddy_info()
        guard sp_pjsip_get_buddy_info(buddyID, &info) == 0 else { return nil }
        return PJSIPBuddyInfo(
            id: info.id,
            status: info.status,
            subscriptionState: info.sub_state,
            uri: cString(from: info.uri),
            statusText: cString(from: info.status_text)
        )
    }

    private func matchPJSIPDevice(
        for hostDevice: HostAudioDevice,
        kind: AudioRouteKind,
        in pjsipDevices: [PJSIPAudioDevice]
    ) -> PJSIPAudioDevice? {
        let candidates = pjsipDevices.filter {
            kind == .microphone ? $0.inputCount > 0 : $0.outputCount > 0
        }
        let hostName = normalizedAudioDeviceName(hostDevice.name)

        if let exact = candidates.first(where: { normalizedAudioDeviceName($0.name) == hostName }) {
            return exact
        }

        if let containing = candidates.first(where: {
            let candidate = normalizedAudioDeviceName($0.name)
            return candidate.contains(hostName) || hostName.contains(candidate)
        }) {
            return containing
        }

        let hostTokens = audioDeviceTokens(hostDevice.name)
        if !hostTokens.isEmpty {
            let scoredMatches = candidates.compactMap { candidate -> (device: PJSIPAudioDevice, score: Int)? in
                let candidateTokens = audioDeviceTokens(candidate.name)
                let overlap = hostTokens.intersection(candidateTokens).count
                guard overlap > 0 else { return nil }
                return (candidate, overlap)
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.device.name.count < rhs.device.name.count
                }
                return lhs.score > rhs.score
            }

            if let best = scoredMatches.first {
                return best.device
            }
        }

        return nil
    }

    private func normalizedAudioDeviceName(_ name: String) -> String {
        name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func audioDeviceTokens(_ name: String) -> Set<String> {
        Set(
            name
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    private func availablePJSIPAudioDevices() -> [PJSIPAudioDevice] {
        guard didInitializePJSIP else { return [] }
        var items = Array(repeating: sp_audio_device_info(), count: 64)
        let count = items.withUnsafeMutableBufferPointer {
            sp_pjsip_enum_audio_devices($0.baseAddress, UInt32($0.count))
        }

        return items.prefix(Int(count)).map {
            PJSIPAudioDevice(
                id: $0.id,
                name: cString(from: $0.name),
                driver: cString(from: $0.driver),
                inputCount: $0.input_count,
                outputCount: $0.output_count
            )
        }
    }

    private func deviceDescription(forPJSIPID id: Int32, kind: AudioRouteKind) -> String {
        if id == spInvalidID {
            return "system-default"
        }
        if let device = availablePJSIPAudioDevices().first(where: { $0.id == id }) {
            return "\(device.name)#\(device.id)"
        }
        return "\(kind.rawValue)-unknown#\(id)"
    }

    private func attemptOutgoingCall(
        for activeUUID: UUID,
        originalNumber: String,
        remainingDestinations: [String],
        attemptedDestinations: [String]
    ) -> Bool {
        guard let registeredAccountID else { return false }
        applyActiveAudioRouting()
        scheduleDeferredAudioRoutingRefresh()

        var remaining = remainingDestinations
        var attempted = attemptedDestinations
        var lastStatus = Int32(-1)

        while let destination = remaining.first {
            remaining.removeFirst()
            diagnostics.log("place call try destination=\(destination)")

            var callID = spInvalidID
            lastStatus = destination.withCString { destination in
                sp_pjsip_make_call(registeredAccountID, destination, &callID)
            }
            attempted.append(destination)

            if lastStatus == 0 {
                diagnostics.log("place call accepted by pjsip callID=\(callID)")
                let activeCall = registerActiveCall(
                    callID: callID,
                    activeUUID: activeUUID,
                    fallbackNumber: originalNumber,
                    fallbackState: .connecting
                )
                pendingOutgoingAttempts[activeCall.id] = PendingOutgoingCallAttempt(
                    originalNumber: originalNumber,
                    attemptedDestinations: attempted,
                    remainingDestinations: remaining,
                    hadMedia: false
                )
                delegate?.sipService(self, didUpdateCall: activeCall)
                return true
            }

            diagnostics.log("place call failed destination=\(destination) status=\(lastStatus) text=\(pjsipStatusText(for: lastStatus))")
        }

        if lastStatus != -1 {
            publishStatus(.disconnected(reason: "Anrufaufbau fehlgeschlagen: \(pjsipStatusText(for: lastStatus))"))
        }
        return false
    }

    private func retryOutgoingCallIfNeeded(activeUUID: UUID, failedCallID: Int32, info: WrappedCallInfo) -> Bool {
        guard let pending = pendingOutgoingAttempts[activeUUID] else { return false }
        guard !pending.hadMedia else { return false }
        guard info.lastStatus >= 300 else { return false }
        guard !pending.remainingDestinations.isEmpty else { return false }

        diagnostics.log(
            "retry outgoing call active=\(activeUUID) failedDestination=\(pending.attemptedDestinations.last ?? "?") " +
            "status=\(info.lastStatus) next=\(pending.remainingDestinations.first ?? "?")"
        )

        unregisterActiveCall(callID: failedCallID)
        pendingOutgoingAttempts.removeValue(forKey: activeUUID)
        publishStatus(.connecting)
        return attemptOutgoingCall(
            for: activeUUID,
            originalNumber: pending.originalNumber,
            remainingDestinations: pending.remainingDestinations,
            attemptedDestinations: pending.attemptedDestinations
        )
    }

    private func normalizedDialTarget(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "sip:", with: "")
            .replacingOccurrences(of: "sips:", with: "")
            .split(separator: "@")
            .first
            .map(String.init) ?? ""
    }

    private func networkPathSignature(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\(String(describing: $0.type)):\($0.name)" }
            .sorted()
            .joined(separator: ",")
        return "\(String(describing: path.status))|dns:\(path.supportsDNS)|v4:\(path.supportsIPv4)|v6:\(path.supportsIPv6)|if:\(interfaces)"
    }

    private func parseRemoteIdentity(from rawValue: String) -> (displayName: String, number: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Unbekannt", "") }

        let displayName: String
        if let range = trimmed.range(of: "<"), range.lowerBound > trimmed.startIndex {
            displayName = trimmed[..<range.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespacesAndNewlines))
        } else {
            displayName = ""
        }

        let uriCandidate: String
        if let start = trimmed.range(of: "<"), let end = trimmed.range(of: ">"), start.upperBound <= end.lowerBound {
            uriCandidate = String(trimmed[start.upperBound..<end.lowerBound])
        } else {
            uriCandidate = trimmed
        }

        let withoutScheme = uriCandidate
            .replacingOccurrences(of: "sip:", with: "")
            .replacingOccurrences(of: "sips:", with: "")
        let userPart = withoutScheme.split(separator: "@").first.map(String.init) ?? withoutScheme
        let number = userPart.isEmpty ? trimmed : userPart
        return (displayName.isEmpty ? number : displayName, number)
    }

    private func startRecordingIfNeeded(for activeUUID: UUID, callID: Int32) {
        guard transcriptionEnabled, let transcriptionDirectoryURL else { return }
        guard callRecordingsByActiveUUID[activeUUID] == nil else { return }

        try? FileManager.default.createDirectory(at: transcriptionDirectoryURL, withIntermediateDirectories: true)
        let recordingID = recordingRecordIDsByActiveUUID[activeUUID] ?? activeUUID
        let localFileURL = transcriptionDirectoryURL.appendingPathComponent("\(recordingID.uuidString)-local.wav")
        let remoteFileURL = transcriptionDirectoryURL.appendingPathComponent("\(recordingID.uuidString)-remote.wav")
        try? FileManager.default.removeItem(at: localFileURL)
        try? FileManager.default.removeItem(at: remoteFileURL)

        var localRecorderID = spInvalidID
        let localStatus = localFileURL.path.withCString { path in
            sp_pjsip_start_call_local_recording(callID, path, &localRecorderID)
        }

        var remoteRecorderID = spInvalidID
        let remoteStatus = remoteFileURL.path.withCString { path in
            sp_pjsip_start_call_remote_recording(callID, path, &remoteRecorderID)
        }

        if localStatus != 0 || remoteStatus != 0 {
            if localStatus == 0 {
                _ = sp_pjsip_stop_call_recording(callID, localRecorderID)
            }
            if remoteStatus == 0 {
                _ = sp_pjsip_stop_call_recording(callID, remoteRecorderID)
            }
            return
        }

        callRecordingsByActiveUUID[activeUUID] = CallRecordingState(
            callID: callID,
            localRecorderID: localRecorderID,
            localFileURL: localFileURL,
            remoteRecorderID: remoteStatus == 0 ? remoteRecorderID : nil,
            remoteFileURL: remoteStatus == 0 ? remoteFileURL : nil
        )
    }

    private func finishRecordingIfNeeded(for activeUUID: UUID) {
        guard let recording = callRecordingsByActiveUUID.removeValue(forKey: activeUUID) else { return }
        recordingRecordIDsByActiveUUID.removeValue(forKey: activeUUID)
        if let localRecorderID = recording.localRecorderID {
            _ = sp_pjsip_stop_call_recording(recording.callID, localRecorderID)
        }
        if let remoteRecorderID = recording.remoteRecorderID {
            _ = sp_pjsip_stop_call_recording(recording.callID, remoteRecorderID)
        }
        if let localFileURL = recording.localFileURL {
            repairWaveHeaderIfNeeded(at: localFileURL)
        }
        if let remoteFileURL = recording.remoteFileURL {
            repairWaveHeaderIfNeeded(at: remoteFileURL)
        }
        delegate?.sipService(
            self,
            didFinishCallRecording: activeUUID,
            localSegments: nil,
            localFileURL: recording.localFileURL,
            remoteFileURL: recording.remoteFileURL
        )
    }

    private func repairWaveHeaderIfNeeded(at fileURL: URL) {
        guard var data = try? Data(contentsOf: fileURL), data.count >= 44 else { return }
        guard String(data: data[0..<4], encoding: .ascii) == "RIFF" else { return }
        guard String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return }
        guard String(data: data[36..<40], encoding: .ascii) == "data" else { return }

        let riffSize = UInt32(max(data.count - 8, 0)).littleEndian
        let dataSize = UInt32(max(data.count - 44, 0)).littleEndian

        data[4] = UInt8(truncatingIfNeeded: riffSize >> 0)
        data[5] = UInt8(truncatingIfNeeded: riffSize >> 8)
        data[6] = UInt8(truncatingIfNeeded: riffSize >> 16)
        data[7] = UInt8(truncatingIfNeeded: riffSize >> 24)
        data[40] = UInt8(truncatingIfNeeded: dataSize >> 0)
        data[41] = UInt8(truncatingIfNeeded: dataSize >> 8)
        data[42] = UInt8(truncatingIfNeeded: dataSize >> 16)
        data[43] = UInt8(truncatingIfNeeded: dataSize >> 24)

        try? data.write(to: fileURL)
    }
}

private struct WrappedCallInfo {
    let state: Int32
    let mediaStatus: Int32
    let remoteInfo: String
    let lastStatus: Int32
    let lastStatusText: String
}

private func cString<T>(from tuple: T) -> String {
    let chars: [CChar] = Mirror(reflecting: tuple).children.compactMap { $0.value as? CChar }
    return chars.withUnsafeBufferPointer {
        guard let baseAddress = $0.baseAddress else { return "" }
        return String(cString: baseAddress)
    }
}

private func pjsipStatusText(for status: Int32) -> String {
    var buffer = Array(repeating: CChar(0), count: 128)
    if sp_pjsip_status_text(status, &buffer, UInt32(buffer.count)) == 0 {
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
    }
    return "PJSIP \(status)"
}

private func makeRingtoneWaveData() -> Data {
    let sampleRate = 16_000
    let tones = [
        (frequency: 523.25, duration: 0.16),
        (frequency: 659.25, duration: 0.18),
        (frequency: 783.99, duration: 0.24),
        (frequency: 659.25, duration: 0.16)
    ]

    func samples(duration: Double, amplitude: Double = 0.0, frequency: Double = 0.0) -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        guard frequency > 0 else { return Array(repeating: 0, count: count) }

        return (0..<count).map { index in
            let time = Double(index) / Double(sampleRate)
            let progress = Double(index) / Double(max(count - 1, 1))
            let attack = min(progress / 0.18, 1.0)
            let release = min((1.0 - progress) / 0.35, 1.0)
            let envelope = min(attack, release)
            let value = sin(2.0 * .pi * frequency * time) * amplitude * envelope
            return Int16(max(-1.0, min(1.0, value)) * Double(Int16.max))
        }
    }

    let phrase = tones.flatMap { tone in
        samples(duration: tone.duration, amplitude: 0.18, frequency: tone.frequency) + samples(duration: 0.05)
    }
    let pcm = phrase + samples(duration: 1.65)

    var data = Data()
    let byteRate = UInt32(sampleRate * 2)
    let blockAlign = UInt16(2)
    let bitsPerSample = UInt16(16)
    let subchunk2Size = UInt32(pcm.count * 2)
    let chunkSize = UInt32(36) + subchunk2Size

    data.append("RIFF".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)

    let subchunk1Size = UInt32(16)
    let audioFormat = UInt16(1)
    let numChannels = UInt16(1)
    data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))

    data.append("data".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian, Array.init))
    for sample in pcm {
        data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init))
    }

    return data
}

private func makeRingbackWaveData() -> Data {
    let sampleRate = 16_000
    let cadence: [(frequencyA: Double, frequencyB: Double, duration: Double)] = [
        (440.0, 480.0, 0.9),
        (0.0, 0.0, 0.2),
        (440.0, 480.0, 0.9),
        (0.0, 0.0, 2.0)
    ]

    func samples(duration: Double, amplitude: Double = 0.0, frequencyA: Double = 0.0, frequencyB: Double = 0.0) -> [Int16] {
        let count = Int(Double(sampleRate) * duration)
        guard frequencyA > 0 || frequencyB > 0 else { return Array(repeating: 0, count: count) }

        return (0..<count).map { index in
            let time = Double(index) / Double(sampleRate)
            let progress = Double(index) / Double(max(count - 1, 1))
            let attack = min(progress / 0.08, 1.0)
            let release = min((1.0 - progress) / 0.12, 1.0)
            let envelope = min(attack, release)
            let toneA = frequencyA > 0 ? sin(2.0 * .pi * frequencyA * time) : 0
            let toneB = frequencyB > 0 ? sin(2.0 * .pi * frequencyB * time) : 0
            let value = ((toneA + toneB) * 0.5) * amplitude * envelope
            return Int16(max(-1.0, min(1.0, value)) * Double(Int16.max))
        }
    }

    let pcm = cadence.flatMap { tone in
        samples(duration: tone.duration, amplitude: 0.14, frequencyA: tone.frequencyA, frequencyB: tone.frequencyB)
    }

    var data = Data()
    let byteRate = UInt32(sampleRate * 2)
    let blockAlign = UInt16(2)
    let bitsPerSample = UInt16(16)
    let subchunk2Size = UInt32(pcm.count * 2)
    let chunkSize = UInt32(36) + subchunk2Size

    data.append("RIFF".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian, Array.init))
    data.append("WAVE".data(using: .ascii)!)
    data.append("fmt ".data(using: .ascii)!)

    let subchunk1Size = UInt32(16)
    let audioFormat = UInt16(1)
    let numChannels = UInt16(1)
    data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian, Array.init))
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian, Array.init))

    data.append("data".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian, Array.init))
    for sample in pcm {
        data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init))
    }

    return data
}
