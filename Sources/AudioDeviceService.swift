import AppKit
import CoreAudio
import Foundation

final class AudioDeviceService {
    static let systemDefaultID = "system-default"

    func loadDevices() -> [AudioRouteKind: [HostAudioDevice]] {
        [
            .ringtone: defaultOutputOption(kind: .ringtone) + outputDevices(kind: .ringtone),
            .speaker: defaultOutputOption(kind: .speaker) + outputDevices(kind: .speaker),
            .microphone: defaultInputOption() + inputDevices()
        ]
    }

    func preferredDeviceName(for kind: AudioRouteKind, selectedIDs: [String], devices: [HostAudioDevice]) -> String {
        let explicitDevices = selectedIDs.filter { $0 != Self.systemDefaultID }
        for id in explicitDevices {
            if let device = devices.first(where: { $0.id == id && $0.isOnline }) {
                return device.name
            }
        }

        if selectedIDs.contains(Self.systemDefaultID) {
            return "System Default"
        }

        return "Kein aktives Gerät"
    }

    private func defaultOutputOption(kind: AudioRouteKind) -> [HostAudioDevice] {
        [HostAudioDevice(id: Self.systemDefaultID, coreAudioID: 0, name: "System Default", isOnline: true, kind: kind)]
    }

    private func defaultInputOption() -> [HostAudioDevice] {
        [HostAudioDevice(id: Self.systemDefaultID, coreAudioID: 0, name: "System Default", isOnline: true, kind: .microphone)]
    }

    private func outputDevices(kind: AudioRouteKind) -> [HostAudioDevice] {
        allAudioDeviceIDs().compactMap { deviceID in
            guard hasOutput(deviceID) else { return nil }
            let uid = deviceUID(deviceID) ?? String(deviceID)
            return HostAudioDevice(
                id: uid,
                coreAudioID: deviceID,
                name: deviceName(deviceID),
                isOnline: isOnline(deviceID),
                kind: kind
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func inputDevices() -> [HostAudioDevice] {
        allAudioDeviceIDs().compactMap { deviceID in
            guard hasInput(deviceID) else { return nil }
            let uid = deviceUID(deviceID) ?? String(deviceID)
            return HostAudioDevice(
                id: uid,
                coreAudioID: deviceID,
                name: deviceName(deviceID),
                isOnline: isOnline(deviceID),
                kind: .microphone
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)

        guard AudioObjectGetPropertyData(systemObjectID, &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String {
        stringProperty(
            objectID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        ) ?? "Unbekanntes Gerät"
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func isOnline(_ deviceID: AudioDeviceID) -> Bool {
        intProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        ) == 1
    }

    private func hasOutput(_ deviceID: AudioDeviceID) -> Bool {
        streamConfigurationChannelCount(
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeOutput
        ) > 0
    }

    private func hasInput(_ deviceID: AudioDeviceID) -> Bool {
        streamConfigurationChannelCount(
            objectID: deviceID,
            scope: kAudioObjectPropertyScopeInput
        ) > 0
    }

    private func streamConfigurationChannelCount(objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            return 0
        }

        let audioBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { audioBufferList.deallocate() }

        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &dataSize, audioBufferList) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &name) == noErr else {
            return nil
        }

        return name?.takeUnretainedValue() as String?
    }

    private func intProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value)
        return value
    }
}
