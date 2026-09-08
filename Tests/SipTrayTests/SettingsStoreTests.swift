import Foundation

private final class MemoryPasswords: SIPPasswordStore {
    var value: String?
    var fail = false
    func read() throws -> String? {
        if fail { throw KeychainFailure(status: -1) }
        return value
    }
    func write(_ password: String) throws {
        if fail { throw KeychainFailure(status: -1) }
        value = password.isEmpty ? nil : password
    }
}

@main
struct SettingsStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let legacy = Data(#"{"sip":{"server":"example.test","username":"fixture","password":"test-only-password","displayName":"Test"}}"#.utf8)
        try legacy.write(to: url)
        let passwords = MemoryPasswords()
        let store = SettingsStore(fileURL: url, passwords: passwords)
        var settings = store.load()
        precondition(store.loadError == nil)
        precondition(passwords.value == "test-only-password")
        precondition(settings.sip.password == passwords.value)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        precondition((json["sip"] as! [String: Any])["password"] == nil)
        precondition(store.load().sip.password == "test-only-password")
        settings.sip.password = "replacement-fixture"
        try store.save(settings)
        precondition(store.load().sip.password == "replacement-fixture")
        settings.sip.password = ""
        try store.save(settings)
        precondition(passwords.value == nil)

        try legacy.write(to: url)
        passwords.fail = true
        let failed = store.load()
        precondition(store.loadError != nil && failed.sip.password.isEmpty)
        precondition(failed.sip.username == "fixture")
        let afterFailedLoad = try Data(contentsOf: url)
        precondition(afterFailedLoad == legacy)
        do {
            try store.save(failed)
            fatalError("Save after failed migration must be blocked")
        } catch {}
        let afterBlockedSave = try Data(contentsOf: url)
        precondition(afterBlockedSave == legacy)
        passwords.fail = false
        _ = store.load()
        precondition(store.loadError == nil)
        passwords.fail = true
        let before = try Data(contentsOf: url)
        do {
            try store.save(settings)
            fatalError("Save must report Keychain failure")
        } catch {}
        let afterFailedSave = try Data(contentsOf: url)
        precondition(afterFailedSave == before)
        print("Settings migration, reload, update, deletion and failure checks passed; no real Keychain access.")
    }
}
