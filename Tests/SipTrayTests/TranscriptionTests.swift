import Foundation
import AVFoundation

private func XCTAssertEqual<T: Equatable>(_ first: T, _ second: T, file: StaticString = #file, line: UInt = #line) {
    precondition(first == second, "Expected \(second), got \(first)", file: file, line: line)
}
private func XCTAssertTrue(_ value: Bool) { precondition(value) }
private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
private func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
private func XCTFail(_ message: String) { fatalError(message) }

@main
struct TranscriptionTests {
    static func main() async throws {
        let tests = Self()
        tests.testEnvAssignments()
        try tests.testOldSettingsRetainAccountAndDoNotEnableCloud()
        try tests.testSelectionsRoundTripWithoutImportedKeys()
        try await tests.testOpenAIRequestAndTimedResponse()
        try await tests.testGeminiRequestAndStructuredResponse()
        await tests.testHTTPFailureDoesNotReturnTranscriptOrExposeBody()
        try await tests.testLongRecordingPreservesChunkOffsets()
        await tests.testIncompleteGeminiResponseFails()
        print("8 transcription checks passed (no network requests).")
    }
    func testEnvAssignments() {
        let contents = """
        # GEMINI_API_KEY=ignored
        export GEMINI_API_KEY = "test-gemini" # comment
        export\tOPENAI_API_KEY='test-openai'
        UNRELATED=irrelevant
        """
        XCTAssertEqual(HomeEnv.parse(contents, name: "GEMINI_API_KEY"), "test-gemini")
        XCTAssertEqual(HomeEnv.parse(contents, name: "OPENAI_API_KEY"), "test-openai")
        XCTAssertNil(HomeEnv.parse(contents, name: "MISSING"))
        XCTAssertNil(HomeEnv.parse("GEMINI_API_KEY=''", name: "GEMINI_API_KEY"))
        XCTAssertEqual(HomeEnv.parse("GEMINI_API_KEY=abc # note", name: "GEMINI_API_KEY"), "abc")
        XCTAssertNil(HomeEnv.parse("GEMINI_API_KEY=\"unfinished", name: "GEMINI_API_KEY"))
        XCTAssertEqual(HomeEnv.parse("GEMINI_API_KEY=first\nGEMINI_API_KEY=last", name: "GEMINI_API_KEY"), "last")
    }

    func testOldSettingsRetainAccountAndDoNotEnableCloud() throws {
        let data = Data(#"{"sip":{"server":"sip.example.test","username":"alice","password":"fixture","displayName":"Alice"},"transcriptionEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.sip.username, "alice")
        XCTAssertTrue(settings.transcriptionEnabled)
        XCTAssertEqual(settings.transcriptionProvider ?? .apple, .apple)
        XCTAssertFalse(settings.useGeminiAPIKeyFromHomeEnv)
    }

    func testSelectionsRoundTripWithoutImportedKeys() throws {
        var settings = AppSettings()
        settings.transcriptionProvider = .openai
        settings.useOpenAIKeyFromHomeEnv = true
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"geminiAPIKey":"old-secret"}"#.utf8))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("old-secret"))
    }

    func testOpenAIRequestAndTimedResponse() async throws {
        let client = client(provider: .openai)
        let result = try await client.request(Data("audio-fixture".utf8))
        XCTAssertEqual(result.segments.first?.text, "Hallo")
        XCTAssertEqual(result.segments.first?.start, 1)
    }

    func testGeminiRequestAndStructuredResponse() async throws {
        let client = client(provider: .gemini)
        let result = try await client.request(Data("audio-fixture".utf8))
        XCTAssertEqual(result.segments.first?.text, "Hallo")
    }

    func testHTTPFailureDoesNotReturnTranscriptOrExposeBody() async {
        var client = client(provider: .openai)
        client = CloudTranscription(provider: .openai, apiKey: "reject-fixture", session: client.session)
        do {
            _ = try await client.request(Data())
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-body"))
        }
    }

    func testLongRecordingPreservesChunkOffsets() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 130)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let segments = try await client(provider: .openai).transcribe(url, speaker: .remote)
        // AVAudioFile may return fewer frames than requested, even before EOF.
        let input = try AVAudioFile(forReading: url)
        let firstChunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8000 * 120)!
        try input.read(into: firstChunk)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.timestamp), [1, 1 + Double(firstChunk.frameLength) / 8000])
        XCTAssertTrue(segments.allSatisfy { $0.speaker == .remote })
    }

    func testIncompleteGeminiResponseFails() async {
        let session = client(provider: .gemini).session
        let client = CloudTranscription(provider: .gemini, apiKey: "incomplete-fixture", session: session)
        do {
            _ = try await client.request(Data())
            XCTFail("Expected incomplete response to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nicht abgeschlossen"))
        }
    }

    private func client(provider: TranscriptionProvider) -> CloudTranscription {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TranscriptionProtocol.self]
        return CloudTranscription(provider: provider, apiKey: "test-fixture", session: URLSession(configuration: config))
    }
}

private final class TranscriptionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let rejected = request.value(forHTTPHeaderField: "Authorization") == "Bearer reject-fixture"
        let incomplete = request.value(forHTTPHeaderField: "x-goog-api-key") == "incomplete-fixture"
        let isOpenAI = request.url!.host == "api.openai.com"
        XCTAssertEqual(request.httpMethod, "POST")
        if !rejected && !incomplete {
            XCTAssertEqual(request.value(forHTTPHeaderField: isOpenAI ? "Authorization" : "x-goog-api-key"),
                           isOpenAI ? "Bearer test-fixture" : "test-fixture")
        }
        let transcript = #"{"segments":[{"start":1,"end":2,"text":"Hallo"}]}"#
        let responseData: Data
        if rejected {
            responseData = Data("sensitive-body".utf8)
        } else if isOpenAI {
            responseData = Data(transcript.utf8)
        } else {
            responseData = try! JSONSerialization.data(withJSONObject: [
                "status": incomplete ? "in_progress" : "completed",
                "steps": [["type": "model_output", "content": [["type": "text", "text": transcript]]]]
            ])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
