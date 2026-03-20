import Foundation

enum TranscriptUserRole {
    case caller
    case callee

    var germanTitle: String {
        switch self {
        case .caller:
            return "Anrufer"
        case .callee:
            return "Angerufener"
        }
    }
}

struct TranscriptParticipant {
    let name: String
    let number: String

    var displayName: String {
        name.isEmpty ? "Unbekannt" : name
    }

    var displayNumber: String {
        number.isEmpty ? "Unbekannt" : number
    }
}

struct GeminiTranscriptPostProcessor {
    func process(
        transcript: String,
        apiKey: String,
        modelName: String,
        callDate: Date,
        caller: TranscriptParticipant,
        callee: TranscriptParticipant
    ) async -> String? {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAPIKey.isEmpty, !trimmedModelName.isEmpty, !trimmedTranscript.isEmpty else { return nil }

        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(trimmedModelName):generateContent") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "key", value: trimmedAPIKey)]
        guard let url = components.url else { return nil }

        let formatter = ISO8601DateFormatter()
        let callDateString = formatter.string(from: callDate)
        let prompt = """
        Ich habe ein transcript von einem telefongespräch. bereite es so auf, dass es wie ein dialog gestaltet ist und korrigiere es ggf!

        Zusatzinformationen:
        - Zeitpunkt des Anrufs: \(callDateString)
        - Anrufer Name: \(caller.displayName)
        - Anrufer Telefonnummer: \(caller.displayNumber)
        - Angerufener Name: \(callee.displayName)
        - Angerufener Telefonnummer: \(callee.displayNumber)
        - Leite soweit möglich her, welche Person der Anrufer und welche der Angerufene ist.
        - Teile den Dialog diesen Personen mit Namen und Nummern korrekt zu.
        - Gib ausschließlich den Dialog wieder
        - Gib nur reinen Text zurück, kein Markdown, keine Überschriften, keine Listen, keine Erklärungen, keine Anmerkungen.
        - Erfinde keinen Inhalt hinzu
        - Wenn eine Stelle unklar ist, lasse sie möglichst nah am Mitschnitt statt sie zu erfinden.

        Beispiel:
        Anrufer: Hallo, ist das \(caller.displayName)?
        Angerufener: Ja, hallo, ist das \(callee.displayName)?
        Anrufer: Ja, ich habe eine Frage zu meinem Konto.
        Angerufener: Ja, ich kann Ihnen dabei helfen.
        Anrufer: Ich möchte wissen, wie viel Geld ich noch auf meinem Konto habe.
        Angerufener: Ihr Kontostand beträgt 1000€.
        Anrufer: Vielen Dank.
        Angerufener: Bitte schön.

        Hier der Mitschnitt:
        \(trimmedTranscript)
        """

        let requestBody = GenerateContentRequest(
            contents: [
                .init(parts: [.init(text: prompt)])
            ],
            generationConfig: .init(temperature: 0.2, topP: 0.8, maxOutputTokens: 1024)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONEncoder().encode(requestBody)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
            let text = decoded.candidates?
                .compactMap { $0.content?.parts?.compactMap(\.text).joined(separator: "\n") }
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch {
            return nil
        }
    }
}

private struct GenerateContentRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }

        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double
        let topP: Double
        let maxOutputTokens: Int
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]?
        }

        let content: Content?
    }

    let candidates: [Candidate]?
}
