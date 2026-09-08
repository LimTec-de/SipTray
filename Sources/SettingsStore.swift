import Foundation

final class SettingsStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let passwords: SIPPasswordStore
    private(set) var loadError: Error?

    init(fileURL: URL? = nil, passwords: SIPPasswordStore = KeychainSIPPasswordStore()) {
        self.passwords = passwords
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SipTray", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? directory.appendingPathComponent("settings.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> AppSettings {
        var settings = AppSettings()
        loadError = nil
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                settings = try decoder.decode(AppSettings.self, from: Data(contentsOf: fileURL))
            }
            if !settings.sip.password.isEmpty {
                // Commit to Keychain first; a failed migration leaves the original file intact.
                try passwords.write(settings.sip.password)
                try encoder.encode(settings).write(to: fileURL, options: .atomic)
            } else {
                settings.sip.password = try passwords.read() ?? ""
            }
        } catch {
            loadError = error
            settings.sip.password = ""
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        // Never overwrite credentials after a failed load with the empty UI value.
        if let loadError { throw loadError }
        let data = try encoder.encode(settings)
        try passwords.write(settings.sip.password)
        try data.write(to: fileURL, options: .atomic)
    }
}
