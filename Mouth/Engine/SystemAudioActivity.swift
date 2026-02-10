import Foundation
import CoreAudio

enum SystemAudioActivity {
    static func isOutputDeviceRunningSomewhere() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status1 == noErr, deviceID != 0 else {
            return false
        }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)

        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status2 = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &addr,
            0,
            nil,
            &size,
            &running
        )

        guard status2 == noErr else {
            return false
        }

        return running != 0
    }
}
