import Foundation
import AppKit
import IOKit.hidsystem

enum MediaKeyController {
    // Mark events we synthesize so we can ignore them in event taps.
    static let eventSourceUserDataMagic: Int64 = 0x4D4F555448 // "MOUTH"

    // Uses the system-defined event mechanism (same path as media keys).
    // Best-effort: posting can be ignored depending on system/security state.
    static func togglePlayPause() {
        postMediaKey(key: Int32(NX_KEYTYPE_PLAY))
    }

    private static func postMediaKey(key: Int32) {
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
