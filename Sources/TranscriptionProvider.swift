import Foundation

enum TranscriptionProvider: String, Codable, CaseIterable {
    case apple, gemini, openai

    var title: String {
        switch self {
        case .apple: return "Apple Spracherkennung"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        }
    }

    var keyName: String { self == .openai ? "OPENAI_API_KEY" : "GEMINI_API_KEY" }
}

enum HomeEnv {
    static func key(_ name: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text, name: name)
    }

    // Read assignments as data; never execute shell code or expand variables.
    static func parse(_ text: String, name: String) -> String? {
        var result: String?
        for line in text.components(separatedBy: .newlines) {
            var assignment = line.trimmingCharacters(in: .whitespaces)
            if assignment.hasPrefix("export ") || assignment.hasPrefix("export\t") {
                assignment = String(assignment.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            guard let equals = assignment.firstIndex(of: "="),
                  assignment[..<equals].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = String(assignment[assignment.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard let end = value.dropFirst().firstIndex(of: quote) else { continue }
                let suffix = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
                guard suffix.isEmpty || suffix.hasPrefix("#") else { continue }
                value = String(value[value.index(after: value.startIndex)..<end])
            } else if value.hasPrefix("#") {
                value = ""
            } else if let comment = value.range(of: #"\s+#"#, options: .regularExpression) {
                value = String(value[..<comment.lowerBound])
            }
            result = value.isEmpty ? nil : value
        }
        return result
    }
}

struct TranscriptionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
