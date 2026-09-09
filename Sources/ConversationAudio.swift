import AVFoundation
import Foundation

enum ConversationAudio {
    // Both PJSIP recorders use the same conference clock and start at call media activation.
    static func mix(local: URL, remote: URL, output: URL) throws -> TimeInterval {
        let files = try [local, remote].map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        let rate = files[0].processingFormat.sampleRate
        guard files.allSatisfy({ $0.processingFormat.sampleRate == rate && $0.processingFormat.channelCount == 1 }),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw TranscriptionFailure(message: "Die Gesprächsspuren haben kein kompatibles Mono-Audioformat.")
        }
        let length = files.map(\.length).max() ?? 0
        guard length > 0 else { throw TranscriptionFailure(message: "Die Gesprächsaufnahme ist leer.") }
        let writer = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var position: AVAudioFramePosition = 0
        while position < length {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, length - position))
            mixed.frameLength = count
            let samples = mixed.floatChannelData![0]
            samples.update(repeating: 0, count: Int(count))
            for file in files {
                var consumed: AVAudioFrameCount = 0
                while consumed < count && file.framePosition < file.length {
                    try file.read(into: scratch, frameCount: count - consumed)
                    guard scratch.frameLength > 0 else {
                        throw TranscriptionFailure(message: "Eine Gesprächsspur konnte nicht vollständig gelesen werden.")
                    }
                    for index in 0..<Int(scratch.frameLength) {
                        samples[Int(consumed) + index] += scratch.floatChannelData![0][index] * 0.5
                    }
                    consumed += scratch.frameLength
                }
            }
            try writer.write(from: mixed)
            position += AVAudioFramePosition(count)
        }
        return Double(length) / rate
    }
}
