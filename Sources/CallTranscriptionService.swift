import AVFoundation
import Foundation
import Speech

final class CallTranscriptionService: @unchecked Sendable {
    enum TranscriptSpeaker: String {
        case local
        case remote

        var title: String {
            switch self {
            case .local:
                return "Du"
            case .remote:
                return "Gegenseite"
            }
        }
    }

    struct TranscriptSegment {
        let speaker: TranscriptSpeaker
        let timestamp: TimeInterval
        let duration: TimeInterval
        let text: String
    }

    private let directoryURL: URL
    private var activeRecognizers: [String: SFSpeechRecognizer] = [:]
    private var activeTasks: [String: SFSpeechRecognitionTask] = [:]
    private var timeoutWorkItems: [String: DispatchWorkItem] = [:]

    var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("SipTray", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryURL = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        cleanupStaleArtifacts(olderThanDays: 7)
    }

    func startIfNeeded(for callID: UUID, enabled: Bool) {
        _ = callID
        guard enabled else { return }
        requestSpeechAuthorizationIfNeeded()
    }

    func requestAuthorization(completion: ((SFSpeechRecognizerAuthorizationStatus) -> Void)? = nil) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion?(status)
            }
        }
    }

    func recordingURL(for callID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(callID.uuidString).wav")
    }

    var recordingsDirectoryURL: URL {
        directoryURL
    }

    func recordingURL(for callID: UUID, speaker: TranscriptSpeaker) -> URL {
        directoryURL.appendingPathComponent("\(callID.uuidString)-\(speaker.rawValue).wav")
    }

    func prepareRecordingFile(_ fileURL: URL) -> URL? {
        waitForRecordingToStabilize(fileURL)
        let preparedURL = preparedRecordingURL(for: fileURL)
        for _ in 0..<8 {
            if createPlayableRecordingCopy(from: fileURL, to: preparedURL), isPlayableRecording(preparedURL) {
                return preparedURL
            }
            Thread.sleep(forTimeInterval: 0.35)
        }
        return isPlayableRecording(preparedURL) ? preparedURL : nil
    }

    func audioOnsetOffset(for fileURL: URL) -> TimeInterval {
        guard let audioFile = try? AVAudioFile(forReading: fileURL) else { return 0 }
        let format = audioFile.processingFormat
        let frameCapacity: AVAudioFrameCount = 2048
        let threshold: Float = 0.015
        var scannedFrames: AVAudioFramePosition = 0

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { break }
            do {
                try audioFile.read(into: buffer)
            } catch {
                break
            }

            let frameLength = Int(buffer.frameLength)
            if frameLength == 0 {
                break
            }

            if let offset = firstFrameAboveThreshold(in: buffer, threshold: threshold) {
                return Double(scannedFrames + AVAudioFramePosition(offset)) / format.sampleRate
            }

            scannedFrames += AVAudioFramePosition(frameLength)
        }

        return 0
    }

    func stopIfNeeded(for callID: UUID, enabled: Bool, completion: @escaping (String?) -> Void) {
        _ = callID
        _ = enabled
        completion(nil)
    }

    func transcribeIfNeeded(fileURL: URL, enabled: Bool, completion: @escaping (String?) -> Void) {
        transcribeSegmentsIfNeeded(fileURL: fileURL, speaker: .remote, enabled: enabled) { segments in
            let text = segments?
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(text?.isEmpty == false ? text : nil)
        }
    }

    func transcribeSegmentsIfNeeded(
        fileURL: URL,
        speaker: TranscriptSpeaker,
        enabled: Bool,
        completion: @escaping ([TranscriptSegment]?) -> Void
    ) {
        guard enabled else {
            completion(nil)
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            completion(nil)
            return
        }

        guard isPlayableRecording(fileURL) else {
            completion(nil)
            return
        }

        let proceed: () -> Void = { [weak self, directoryURL] in
            guard let self else {
                completion(nil)
                return
            }

            let taskKey = fileURL.path
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "de_DE")) ?? SFSpeechRecognizer()
            guard let recognizer else {
                completion(nil)
                return
            }

            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = true
            self.activeRecognizers[taskKey] = recognizer

            var didComplete = false
            var latestSegments: [TranscriptSegment] = []
            self.timeoutWorkItems[taskKey]?.cancel()
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !didComplete else { return }
                didComplete = true
                self.activeTasks[taskKey]?.cancel()
                self.activeTasks.removeValue(forKey: taskKey)
                self.activeRecognizers.removeValue(forKey: taskKey)
                self.timeoutWorkItems.removeValue(forKey: taskKey)
                completion(latestSegments.isEmpty ? nil : latestSegments)
            }
            self.timeoutWorkItems[taskKey] = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeoutWorkItem)

            let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                guard !didComplete else { return }

                if let result {
                    latestSegments = Self.convertSegments(result.bestTranscription.segments, speaker: speaker)
                }

                if let result, result.isFinal {
                    didComplete = true
                    self.timeoutWorkItems[taskKey]?.cancel()
                    self.timeoutWorkItems.removeValue(forKey: taskKey)
                    self.activeTasks.removeValue(forKey: taskKey)
                    self.activeRecognizers.removeValue(forKey: taskKey)
                    let finalSegments = Self.convertSegments(result.bestTranscription.segments, speaker: speaker)
                    completion(finalSegments.isEmpty ? latestSegments : finalSegments)
                    return
                }

                if error != nil {
                    didComplete = true
                    self.timeoutWorkItems[taskKey]?.cancel()
                    self.timeoutWorkItems.removeValue(forKey: taskKey)
                    self.activeTasks.removeValue(forKey: taskKey)
                    self.activeRecognizers.removeValue(forKey: taskKey)
                    completion(latestSegments.isEmpty ? nil : latestSegments)
                }
            }
            self.activeTasks[taskKey]?.cancel()
            self.activeTasks[taskKey] = task
            _ = directoryURL
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            proceed()
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized {
                        proceed()
                    } else {
                        completion(nil)
                    }
                }
            }
        default:
            completion(nil)
        }
    }

    func mergeTranscript(local: String?, remote: String?) -> String? {
        let localText = local?.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteText = remote?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteText, !remoteText.isEmpty {
            return remoteText
        }
        return localText?.isEmpty == false ? localText : nil
    }

    func mergeSegments(local: [TranscriptSegment], remote: [TranscriptSegment]) -> String? {
        let remoteSegments = remote
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        let remoteText = renderSegmentsWithPauseMarkers(remoteSegments)
        if !remoteText.isEmpty {
            return remoteText
        }

        let localSegments = local
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        let localText = renderSegmentsWithPauseMarkers(localSegments)
        return localText.isEmpty ? nil : localText
    }

    private func renderSegmentsWithPauseMarkers(_ segments: [TranscriptSegment]) -> String {
        guard let first = segments.first else { return "" }

        let pauseThreshold: TimeInterval = 1.2
        var parts: [String] = [first.text]
        var previousEnd = first.timestamp + max(first.duration, 0.12)

        for segment in segments.dropFirst() {
            let currentStart = segment.timestamp
            if currentStart - previousEnd >= pauseThreshold {
                parts.append("{PAUSE}")
            }
            parts.append(segment.text)
            previousEnd = segment.timestamp + max(segment.duration, 0.12)
        }

        return parts.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    func cleanupRecordingArtifacts(rawFileURLs: [URL?], preparedFileURLs: [URL?]) {
        let urls = (rawFileURLs + preparedFileURLs).compactMap { $0 }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cleanupStaleArtifacts(olderThanDays days: Int) {
        let cutoff = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for fileURL in files {
            guard fileURL.pathExtension.lowercased() == "wav" else { continue }
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            guard modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func requestSpeechAuthorizationIfNeeded() {
        guard authorizationStatus == .notDetermined else { return }
        requestAuthorization()
    }

    private func waitForRecordingToStabilize(_ fileURL: URL) {
        var lastSize: UInt64?
        var stableIterations = 0

        for _ in 0..<12 {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.uint64Value
            if size == lastSize, size != nil {
                stableIterations += 1
            } else {
                stableIterations = 0
                lastSize = size
            }

            if stableIterations >= 2 {
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func isPlayableRecording(_ fileURL: URL) -> Bool {
        do {
            _ = try AVAudioFile(forReading: fileURL)
            return true
        } catch {
            return false
        }
    }

    private func preparedRecordingURL(for fileURL: URL) -> URL {
        fileURL.deletingPathExtension().appendingPathExtension("prepared.wav")
    }

    private func createPlayableRecordingCopy(from sourceURL: URL, to destinationURL: URL) -> Bool {
        guard var data = try? Data(contentsOf: sourceURL), data.count >= 44 else { return false }
        guard String(data: data[0..<4], encoding: .ascii) == "RIFF" else { return false }
        guard String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return false }
        guard String(data: data[36..<40], encoding: .ascii) == "data" else { return false }

        let riffSize = UInt32(max(data.count - 8, 0))
        let dataSize = UInt32(max(data.count - 44, 0))

        writeLittleEndian(riffSize, to: &data, at: 4)
        writeLittleEndian(dataSize, to: &data, at: 40)
        do {
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func writeLittleEndian(_ value: UInt32, to data: inout Data, at offset: Int) {
        let littleEndian = value.littleEndian
        data[offset + 0] = UInt8(truncatingIfNeeded: littleEndian >> 0)
        data[offset + 1] = UInt8(truncatingIfNeeded: littleEndian >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: littleEndian >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: littleEndian >> 24)
    }

    private static func convertSegments(
        _ segments: [SFTranscriptionSegment],
        speaker: TranscriptSpeaker
    ) -> [TranscriptSegment] {
        segments.compactMap { segment in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                speaker: speaker,
                timestamp: segment.timestamp,
                duration: segment.duration,
                text: text
            )
        }
    }

    private func firstFrameAboveThreshold(in buffer: AVAudioPCMBuffer, threshold: Float) -> Int? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return nil }

        for frame in 0..<frameLength {
            var maxValue: Float = 0
            for channel in 0..<channelCount {
                maxValue = max(maxValue, abs(channelData[channel][frame]))
            }
            if maxValue >= threshold {
                return frame
            }
        }
        return nil
    }
}
