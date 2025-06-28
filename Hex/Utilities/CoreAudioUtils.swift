import Foundation
import AudioToolbox
import CoreAudio

// MARK: - Constants
extension AudioObjectID {
    /// Convenience for `kAudioObjectSystemObject`.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Convenience for `kAudioObjectUnknown`.
    static let unknown = kAudioObjectUnknown
    /// `true` if this object has the value of `kAudioObjectUnknown`.
    var isUnknown: Bool { self == .unknown }
    /// `false` if this object has the value of `kAudioObjectUnknown`.
    var isValid: Bool { !isUnknown }
}

// MARK: - Generic property helpers (subset used by AudioTapService)
extension AudioObjectID {
    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        try read(AudioObjectPropertyAddress(mSelector: selector,
                                            mScope: scope,
                                            mElement: element),
                 defaultValue: defaultValue)
    }

    private func read<T>(_ address: AudioObjectPropertyAddress,
                         defaultValue: T) throws -> T {
        var addr = address
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &dataSize)
        guard err == noErr else { throw "Error reading data size for \(address): \(err)" }

        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &dataSize, ptr)
        }
        guard err == noErr else { throw "Error reading data for \(address): \(err)" }
        return value
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        try read(AudioObjectPropertyAddress(mSelector: selector,
                                            mScope: scope,
                                            mElement: element),
                 defaultValue: "" as CFString) as String
    }

    func readProcessBundleID() -> String? {
        (try? readString(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
    }

    func readProcessIsRunning() -> Bool {
        (try? read(kAudioProcessPropertyIsRunning, defaultValue: 0)) == 1
    }

    /// Reads the default system output device.
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &size, &device)
        guard err == noErr else { throw "Error reading default output device: \(err)" }
        return device
    }

    /// Reads the list of audio process object IDs.
    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readProcessList()
    }

    /// Instance helper for system object to read process list.
    func readProcessList() throws -> [AudioObjectID] {
        guard self == .system else { throw "Only supported for system object." }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "Error reading data size for process list: \(err)" }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var list = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, &list)
        guard err == noErr else { throw "Error reading process list: \(err)" }
        return list
    }

    /// Reads the basic stream description for a process tap / device.
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - AudioDevice helpers
extension AudioDeviceID {
    func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &size, &device)
        guard err == noErr else { throw "Error reading default output device: \(err)" }
        return device
    }
}

// MARK: - Utility
private extension UInt32 {
    var fourCharString: String {
        String(cString: [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
            0
        ])
    }
}

extension AudioObjectPropertyAddress: @retroactive CustomStringConvertible {
    public var description: String {
        let elementDesc = mElement == kAudioObjectPropertyElementMain ? "main" : mElement.fourCharString
        return "\(mSelector.fourCharString)/\(mScope.fourCharString)/\(elementDesc)"
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
} 