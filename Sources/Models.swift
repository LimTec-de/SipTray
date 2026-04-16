import Foundation

struct Contact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var number: String

    init(id: UUID = UUID(), name: String, number: String) {
        self.id = id
        self.name = name
        self.number = number
    }
}

enum FavoritePresenceState: String, Codable, Equatable {
    case unknown
    case checking
    case online
    case offline

    var colorName: String {
        switch self {
        case .online:
            return "green"
        case .offline:
            return "red"
        case .unknown, .checking:
            return "orange"
        }
    }
}

struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable, CaseIterable {
        case incoming
        case outgoing
        case missed
    }

    enum Disposition: String, Codable, CaseIterable {
        case answered
        case noAnswer
        case busy
        case failed
        case cancelled

        var displayLabel: String {
            switch self {
            case .answered:
                return "angenommen"
            case .noAnswer:
                return "nicht angenommen"
            case .busy:
                return "besetzt"
            case .failed:
                return "fehlgeschlagen"
            case .cancelled:
                return "abgebrochen"
            }
        }
    }

    let id: UUID
    var displayName: String
    var number: String
    var direction: Direction
    var date: Date
    var isFavorite: Bool
    var transcription: String?
    var disposition: Disposition?
    var answeredBy: String?
    var queueName: String?
    var finalDestination: String?
    var ringDuration: TimeInterval?
    var talkDuration: TimeInterval?

    init(
        id: UUID = UUID(),
        displayName: String,
        number: String,
        direction: Direction,
        date: Date = .now,
        isFavorite: Bool = false,
        transcription: String? = nil,
        disposition: Disposition? = nil,
        answeredBy: String? = nil,
        queueName: String? = nil,
        finalDestination: String? = nil,
        ringDuration: TimeInterval? = nil,
        talkDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.number = number
        self.direction = direction
        self.date = date
        self.isFavorite = isFavorite
        self.transcription = transcription
        self.disposition = disposition
        self.answeredBy = answeredBy
        self.queueName = queueName
        self.finalDestination = finalDestination
        self.ringDuration = ringDuration
        self.talkDuration = talkDuration
    }

    var metadataSummary: String? {
        let items = [
            disposition?.displayLabel,
            answeredBy.flatMap { trimmed($0).map { "angenommen von \($0)" } },
            queueName.flatMap { trimmed($0).map { "Queue \($0)" } },
            finalDestination.flatMap { trimmed($0).map { "an \($0)" } },
            talkDuration.flatMap { durationString($0).map { "Dauer \($0)" } },
            ringDuration.flatMap { durationString($0).map { "Klingeln \($0)" } }
        ].compactMap { $0 }

        guard !items.isEmpty else { return nil }
        return items.joined(separator: " · ")
    }

    var preferredDisplayName: String {
        let trimmedDisplayName = trimmed(displayName)
        let trimmedNumber = trimmed(number)

        if let trimmedDisplayName, !Self.isUnknownPlaceholder(trimmedDisplayName) {
            return trimmedDisplayName
        }

        if let trimmedNumber {
            return trimmedNumber
        }

        return "Unbekannt"
    }

    var secondaryDisplayNumber: String? {
        guard let trimmedNumber = trimmed(number), trimmedNumber != preferredDisplayName else {
            return nil
        }
        return trimmedNumber
    }

    private func trimmed(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func isUnknownPlaceholder(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "unbekannt" || normalized == "unknown"
    }

    private func durationString(_ interval: TimeInterval) -> String? {
        guard interval >= 1 else { return nil }
        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum AudioRouteKind: String, Codable, CaseIterable {
    case ringtone
    case speaker
    case microphone
}

struct HostAudioDevice: Identifiable, Equatable {
    let id: String        // stabile UID (kAudioDevicePropertyDeviceUID) oder "system-default"
    let coreAudioID: UInt32  // transiente CoreAudio Object-ID, nur für Laufzeit-Operationen
    let name: String
    let isOnline: Bool
    let kind: AudioRouteKind

    var displayLabel: String {
        isOnline ? name : "\(name) (offline)"
    }
}

struct SIPSettings: Codable, Equatable {
    var server: String = ""
    var username: String = ""
    var password: String = ""
    var displayName: String = ""

    var isComplete: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }
}

struct AudioRouteSelection: Codable, Equatable {
    var ringtoneDeviceIDs: [String] = ["system-default"]
    var speakerDeviceIDs: [String] = ["system-default"]
    var microphoneDeviceIDs: [String] = ["system-default"]

    func ids(for kind: AudioRouteKind) -> [String] {
        switch kind {
        case .ringtone:
            ringtoneDeviceIDs
        case .speaker:
            speakerDeviceIDs
        case .microphone:
            microphoneDeviceIDs
        }
    }

    mutating func setIDs(_ ids: [String], for kind: AudioRouteKind) {
        let sanitized = ids.isEmpty ? ["system-default"] : ids
        switch kind {
        case .ringtone:
            ringtoneDeviceIDs = sanitized
        case .speaker:
            speakerDeviceIDs = sanitized
        case .microphone:
            microphoneDeviceIDs = sanitized
        }
    }
}

struct AppSettings: Codable, Equatable {
    var sip = SIPSettings()
    var audio = AudioRouteSelection()
    var rememberedAudioDeviceNames: [String: String] = [:]
    var launchAtLogin = false
    var transcriptionEnabled = false
    var geminiAPIKey = ""
    var useGeminiAPIKeyFromHomeEnv = false
    var geminiModelName = "gemini-3.1-flash-lite-preview"
    var numberRewritePattern = "^\\+"
    var numberRewriteReplacement = "00"
}

struct IncomingCall: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let number: String
    let date: Date

    init(id: UUID = UUID(), displayName: String, number: String, date: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.number = number
        self.date = date
    }
}

struct ActiveCall: Identifiable, Equatable {
    enum State: String, Equatable {
        case connecting
        case active
        case onHold
        case conference
    }

    let id: UUID
    var displayName: String
    var number: String
    var startedAt: Date
    var state: State

    init(
        id: UUID = UUID(),
        displayName: String,
        number: String,
        startedAt: Date = .now,
        state: State = .active
    ) {
        self.id = id
        self.displayName = displayName
        self.number = number
        self.startedAt = startedAt
        self.state = state
    }
}

enum SIPConnectionStatus: Equatable {
    case disconnected(reason: String)
    case connecting
    case connected
    case reconnecting
    case networkUnavailable
    case invalidConfiguration

    var title: String {
        switch self {
        case .disconnected:
            return "Getrennt"
        case .connecting:
            return "Verbinde"
        case .connected:
            return "Verbunden"
        case .reconnecting:
            return "Reconnect"
        case .networkUnavailable:
            return "Offline"
        case .invalidConfiguration:
            return "Nicht konfiguriert"
        }
    }

    var detail: String {
        switch self {
        case let .disconnected(reason):
            return reason
        case .connecting:
            return "Registrierung am VoIP-Server wird aufgebaut."
        case .connected:
            return "Am VoIP-Server registriert."
        case .reconnecting:
            return "Verbindung wird automatisch neu aufgebaut."
        case .networkUnavailable:
            return "Kein verwendbares Netzwerk."
        case .invalidConfiguration:
            return "Server oder SIP-Zugangsdaten fehlen."
        }
    }
}
