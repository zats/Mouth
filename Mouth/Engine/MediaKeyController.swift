import Foundation
import AppKit
import IOKit.hidsystem

enum MediaKeyController {
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
            e.cgEvent?.post(tap: .cghidEventTap)
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
            e.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
