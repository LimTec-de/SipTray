import CoreAudio
import Foundation

final class SystemAudioRouteController {
    private struct Snapshot {
        let input: AudioDeviceID
        let output: AudioDeviceID
        let systemOutput: AudioDeviceID
    }

    private var snapshot: Snapshot?

    func apply(inputDeviceID: String?, outputDeviceID: String?) {
        guard inputDeviceID != nil || outputDeviceID != nil else {
            restoreIfNeeded()
            return
        }

        if snapshot == nil, let current = currentSnapshot() {
            snapshot = current
        }

        if let inputDeviceID, let rawInputID = UInt32(inputDeviceID) {
            let inputID = AudioDeviceID(rawInputID)
            _ = setDefaultDevice(inputID, selector: kAudioHardwarePropertyDefaultInputDevice)
        }

        if let outputDeviceID, let rawOutputID = UInt32(outputDeviceID) {
            let outputID = AudioDeviceID(rawOutputID)
            _ = setDefaultDevice(outputID, selector: kAudioHardwarePropertyDefaultOutputDevice)
            _ = setDefaultDevice(outputID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
    }

    func restoreIfNeeded() {
        guard let snapshot else { return }
        _ = setDefaultDevice(snapshot.input, selector: kAudioHardwarePropertyDefaultInputDevice)
        _ = setDefaultDevice(snapshot.output, selector: kAudioHardwarePropertyDefaultOutputDevice)
        _ = setDefaultDevice(snapshot.systemOutput, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        self.snapshot = nil
    }

    private func currentSnapshot() -> Snapshot? {
        guard
            let input = getDefaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice),
            let output = getDefaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice),
            let systemOutput = getDefaultDevice(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        else {
            return nil
        }
        return Snapshot(input: input, output: output, systemOutput: systemOutput)
    }

    private func getDefaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func setDefaultDevice(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableDeviceID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &mutableDeviceID
        )
        return status == noErr
    }
}
