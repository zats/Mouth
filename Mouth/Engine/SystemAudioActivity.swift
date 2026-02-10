import Foundation
import CoreAudio

enum SystemAudioActivity {
    static func isAnyOtherProcessRunningOutput(excludingPIDs: Set<pid_t> = [getpid()]) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let stSize = AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size)
        guard stSize == noErr, size >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return false
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procIDs = Array(repeating: AudioObjectID(0), count: count)
        let stData = AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &procIDs)
        guard stData == noErr else {
            return false
        }

        for procID in procIDs {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let stPID = AudioObjectGetPropertyData(procID, &pidAddr, 0, nil, &pidSize, &pid)
            guard stPID == noErr else { continue }
            if excludingPIDs.contains(pid) { continue }

            var isRunningOutput: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let stRun = AudioObjectGetPropertyData(procID, &runAddr, 0, nil, &runSize, &isRunningOutput)
            guard stRun == noErr else { continue }

            if isRunningOutput != 0 {
                return true
            }
        }

        return false
    }

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
