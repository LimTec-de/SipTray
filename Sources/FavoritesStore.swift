import Foundation

final class FavoritesStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SIPPhone", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("favorites.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [Contact] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let favorites = try? decoder.decode([Contact].self, from: data)
        else {
            return []
        }
        return favorites
    }

    func save(_ favorites: [Contact]) {
        guard let data = try? encoder.encode(favorites) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
