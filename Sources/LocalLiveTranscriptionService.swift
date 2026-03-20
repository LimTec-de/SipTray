import AVFoundation
import Foundation

final class LocalLiveTranscriptionService {
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var activeCallID: UUID?
    private var outputURL: URL?

    func start(callID: UUID, fileURL: URL) {
        stop()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else { return }

        try? FileManager.default.removeItem(at: fileURL)

        guard let audioFile = try? AVAudioFile(
            forWriting: fileURL,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        ) else {
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            try? audioFile.write(from: buffer)
        }

        engine.prepare()
        try? engine.start()

        self.engine = engine
        self.audioFile = audioFile
        self.activeCallID = callID
        self.outputURL = fileURL
    }

    func stop(callID: UUID) -> URL? {
        guard activeCallID == callID else { return nil }
        let finishedURL = outputURL
        stop()
        return finishedURL
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        engine = nil
        audioFile = nil
        activeCallID = nil
        outputURL = nil
    }
}
