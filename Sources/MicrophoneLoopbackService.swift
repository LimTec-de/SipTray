import AVFoundation
import Foundation

final class MicrophoneLoopbackService {
    enum LoopbackError: LocalizedError {
        case microphonePermissionDenied
        case noInputDevice

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Mikrofonzugriff wurde nicht erlaubt. Bitte in Systemeinstellungen > Datenschutz > Mikrofon fuer SIPPhone aktivieren."
            case .noInputDevice:
                return "Kein Mikrofon verfuegbar."
            }
        }
    }

    private let routeController = SystemAudioRouteController()
    private var engine: AVAudioEngine?
    var onLevelsChanged: ((Float, Float) -> Void)?

    var isRunning: Bool {
        engine != nil
    }

    func start(inputDeviceID: String?, outputDeviceID: String?) throws {
        stop()

        routeController.apply(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let mixerNode = engine.mainMixerNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0 else {
            routeController.restoreIfNeeded()
            throw LoopbackError.noInputDevice
        }

        inputNode.removeTap(onBus: 0)
        mixerNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.normalizedLevel(for: buffer)
            DispatchQueue.main.async {
                self?.onLevelsChanged?(level, -1)
            }
        }

        engine.connect(inputNode, to: mixerNode, format: inputFormat)
        let mixerFormat = mixerNode.outputFormat(forBus: 0)
        mixerNode.installTap(onBus: 0, bufferSize: 1024, format: mixerFormat) { [weak self] buffer, _ in
            let level = Self.normalizedLevel(for: buffer)
            DispatchQueue.main.async {
                self?.onLevelsChanged?(-1, level)
            }
        }

        mixerNode.outputVolume = 1
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        engine = nil
        onLevelsChanged?(0, 0)
        routeController.restoreIfNeeded()
    }

    private static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sum: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let rms = sqrt(sum / Float(frameLength * channelCount))
        return min(max(rms * 4, 0), 1)
    }
}
