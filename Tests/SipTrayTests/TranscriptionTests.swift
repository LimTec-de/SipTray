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
        try await tests.testLongConversationUsesOneTranscript()
        await tests.testIncompleteGeminiResponseFails()
        try await tests.testModelSelection()
        try tests.testConversationMixPreservesBothSidesAndSilence()
        print("10 transcription checks passed (no network requests).")
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

    func testLongConversationUsesOneTranscript() async throws {
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
        let transcript = try await client(provider: .openai).transcribeConversation(local: url, remote: url)
        XCTAssertEqual(transcript, "[00:01] Hallo")
    }

    func testConversationMixPreservesBothSidesAndSilence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rate = 16000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        func track(_ name: String, seconds: Int, toneStart: Int) throws -> URL {
            let url = directory.appendingPathComponent(name + ".wav")
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 16000))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                let time = Double(i) / rate
                buffer.floatChannelData![0][i] = time >= Double(toneStart) ? Float(sin(time * 440 * 2 * .pi) * 0.6) : 0
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
        let local = try track("local", seconds: 1, toneStart: 0)
        let remote = try track("remote", seconds: 3, toneStart: 2)
        let output = directory.appendingPathComponent("conversation.m4a")
        XCTAssertEqual(try ConversationAudio.mix(local: local, remote: remote, output: output), 3)
        let file = try AVAudioFile(forReading: output)
        XCTAssertTrue(abs(Double(file.length) / rate - 3) < 0.15)
        func peak(at seconds: Double) throws -> Float {
            file.framePosition = Int64(seconds * rate)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
            try file.read(into: buffer)
            return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        }
        XCTAssertTrue(try peak(at: 0.5) > 0.1)
        XCTAssertTrue(try peak(at: 1.5) < 0.01)
        XCTAssertTrue(try peak(at: 2.5) > 0.1)
        let result = try JSONDecoder().decode(CloudTranscription.Result.self,
            from: Data(#"{"segments":[{"start":0,"end":1,"text":"Test","speaker":"A"}]}"#.utf8))
        XCTAssertEqual(result.segments.first?.speaker, "A")
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

    func testModelSelection() async throws {
        var settings = AppSettings()
        settings.geminiTranscriptionModel = "custom-audio-model-fixture"
        settings.openAITranscriptionModel = "whisper-1"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.openAITranscriptionModel, "gpt-4o-transcribe-diarize")
        XCTAssertEqual(old.geminiTranscriptionModel, "gemini-3.8-flash")

        var gemini = client(provider: .gemini)
        gemini.model = settings.geminiTranscriptionModel
        let json = try JSONSerialization.jsonObject(with: gemini.makeRequest(Data()).httpBody!) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, settings.geminiTranscriptionModel)
        var openai = client(provider: .openai)
        let defaultBody = String(decoding: try openai.makeRequest(Data()).httpBody!, as: UTF8.self)
        XCTAssertTrue(defaultBody.contains("diarized_json"))
        openai.model = settings.openAITranscriptionModel
        let body = String(decoding: try openai.makeRequest(Data()).httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("whisper-1"))
        XCTAssertTrue(body.contains("verbose_json"))
        XCTAssertTrue(body.contains("timestamp_granularities[]"))
        XCTAssertFalse(body.contains("chunking_strategy"))
        let response = try await openai.request(Data())
        XCTAssertEqual(response.segments.first?.start, 1)
        for invalid in ["", "unsupported-fixture"] {
            openai.model = invalid
            do {
                _ = try openai.makeRequest(Data())
                XCTFail("Invalid model must fail before upload")
            } catch is TranscriptionFailure {}
        }
        gemini.model = "  "
        do {
            _ = try gemini.makeRequest(Data())
            XCTFail("Empty Gemini model must fail before upload")
        } catch is TranscriptionFailure {}
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
