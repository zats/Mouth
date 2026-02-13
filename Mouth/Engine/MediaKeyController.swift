import Foundation
import AppKit
import IOKit.hidsystem

enum MediaKeyController {
    // Mark events we synthesize so we can ignore them in event taps.
    static let eventSourceUserDataMagic: Int64 = 0x4D4F555448 // "MOUTH"
    private static let postingLock = NSLock()
    private static var postingSyntheticMediaKeyCount = 0
    private static var passThroughUntilAbsoluteTime: CFAbsoluteTime = 0
    private static var pendingPlayPausePassThroughEvents = 0

    static var shouldBypassInterception: Bool {
        postingLock.lock()
        defer { postingLock.unlock() }
        return postingSyntheticMediaKeyCount > 0 || CFAbsoluteTimeGetCurrent() <= passThroughUntilAbsoluteTime
    }

    static func consumePlayPausePassThroughIfNeeded(forKeyState keyState: Int32) -> Bool {
        postingLock.lock()
        defer { postingLock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        let withinWindow = now <= passThroughUntilAbsoluteTime

        // Expire stale pending pass-through events if our posting window has elapsed.
        if !withinWindow, postingSyntheticMediaKeyCount == 0 {
            pendingPlayPausePassThroughEvents = 0
        }

        if pendingPlayPausePassThroughEvents > 0, (keyState == 0xA || keyState == 0xB) {
            pendingPlayPausePassThroughEvents -= 1
            return true
        }

        return postingSyntheticMediaKeyCount > 0 || withinWindow
    }

    // Uses the system-defined event mechanism (same path as media keys).
    // Best-effort: posting can be ignored depending on system/security state.
    static func togglePlayPause(trackPassThrough: Bool = true) {
        postMediaKey(key: Int32(NX_KEYTYPE_PLAY), trackPassThrough: trackPassThrough)
    }

    private static func postMediaKey(key: Int32, trackPassThrough: Bool) {
        postingLock.lock()
        postingSyntheticMediaKeyCount += 1
        if trackPassThrough {
            passThroughUntilAbsoluteTime = max(passThroughUntilAbsoluteTime, CFAbsoluteTimeGetCurrent() + 1.0)
        }
        if trackPassThrough, key == Int32(NX_KEYTYPE_PLAY) {
            // We emit keyDown + keyUp.
            pendingPlayPausePassThroughEvents += 2
        }
        postingLock.unlock()
        defer {
            postingLock.lock()
            postingSyntheticMediaKeyCount = max(0, postingSyntheticMediaKeyCount - 1)
            postingLock.unlock()
        }

        // subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS
        // data1 encodes key + (keyDown/keyUp) in the high bits.
        let keyDown: Int32 = 0xA
        let keyUp: Int32 = 0xB

        let downData1 = (key << 16) | (keyDown << 8)
        let upData1 = (key << 16) | (keyUp << 8)

        let modifierFlags = NSEvent.ModifierFlags(rawValue: 0xA00)

        if let e = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(downData1),
            data2: -1
        ) {
            if let cg = e.cgEvent {
                cg.setIntegerValueField(.eventSourceUserData, value: eventSourceUserDataMagic)
                cg.post(tap: .cghidEventTap)
            }
        }

        if let e = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(upData1),
            data2: -1
        ) {
            if let cg = e.cgEvent {
                cg.setIntegerValueField(.eventSourceUserData, value: eventSourceUserDataMagic)
                cg.post(tap: .cghidEventTap)
            }
        }
    }
}
