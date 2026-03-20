import Foundation

final class CallHistoryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SIPPhone", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("recent-calls.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() -> [CallRecord] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let history = try? decoder.decode([CallRecord].self, from: data)
        else {
            return []
        }
        return history
    }

    func save(_ history: [CallRecord]) {
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

