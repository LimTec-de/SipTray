import Foundation

@main
struct ConversationMinutesTests {
    static func main() async throws {
        let transcript = "[00:01] Sprecher A: Ich sende das Angebot.\n[00:03] Sprecher B: Wann?"
        let item: [String: Any] = ["text": "Angebot versenden.", "person": "Sprecher A", "deadline": "",
                                  "source": "[00:01] Sprecher A: Ich sende das Angebot."]
        let payload: [String: Any] = ["summary": "Ein Angebot soll versandt werden. Der Termin ist offen.",
                                    "topics": [item], "decisions": [], "tasks": [item],
                                    "questions": [["text": "Versandtermin offen.", "person": "", "deadline": "",
                                                   "source": "[00:03] Sprecher B: Wann?"]], "risks": []]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        for provider in [TranscriptionProvider.gemini, .openai] {
            let client = ConversationMinutesClient(provider: provider, model: "test-model", apiKey: "test-key")
            let request = try client.makeRequest(transcript: transcript)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            precondition(body["input"] as? String == transcript)
            precondition(body["store"] as? Bool == false)
            precondition(body["model"] as? String == "test-model")
            let response: [String: Any] = ["status": "completed",
                provider == .openai ? "output" : "steps": [[
                    "type": provider == .openai ? "message" : "model_output",
                    "content": [["type": provider == .openai ? "output_text" : "text", "text": json]]
                ]]]
            let formatted = try client.decode(JSONSerialization.data(withJSONObject: response), transcript: transcript)
            for heading in ["Kurzfassung", "Themen", "Entscheidungen", "Aufgaben", "Fragen", "Risiken"] {
                precondition(formatted.contains(heading))
            }
            precondition(formatted.contains("Termin: nicht vereinbart"))
            precondition(formatted.contains("Sprecher A"))
            var call = CallRecord(displayName: "Test", number: "fixture", direction: .outgoing, transcription: transcript)
            call.conversationMinutes = formatted
            call.minutesModel = "test-model"
            let restored = try JSONDecoder().decode(CallRecord.self, from: JSONEncoder().encode(call))
            precondition(restored == call && restored.transcription == transcript)
            var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(call)) as! [String: Any]
            legacy.removeValue(forKey: "conversationMinutes")
            legacy.removeValue(forKey: "minutesModel")
            let old = try JSONDecoder().decode(CallRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
            precondition(old.conversationMinutes == nil && old.transcription == transcript)
            do {
                _ = try client.decode(JSONSerialization.data(withJSONObject: ["status": "incomplete"]), transcript: transcript)
                fatalError("Partial response must fail")
            } catch is TranscriptionFailure {}
            do {
                _ = try client.decode(JSONSerialization.data(withJSONObject: response), transcript: "Unrelated text")
                fatalError("Fabricated source must fail")
            } catch is TranscriptionFailure {}
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FailureProtocol.self]
            let failing = ConversationMinutesClient(provider: provider, model: "test-model", apiKey: "test-key",
                                                     session: URLSession(configuration: config))
            do {
                _ = try await failing.generate(transcript: transcript)
                fatalError("HTTP error must fail")
            } catch {
                precondition(error.localizedDescription.contains("401"))
                precondition(!error.localizedDescription.contains("private-response"))
            }
        }
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        precondition(oldSettings.minutesProvider == nil)
        print("Minutes checks passed: both providers, source validation, partial/HTTP failure, persistence and legacy migration; no network access.")
    }
}

private final class FailureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("private-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
