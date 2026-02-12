import AppKit
import Foundation
import IOKit.hidsystem

/// Captures the play/pause media key and can swallow it (so it doesn't reach other apps).
///
/// This uses a CGEventTap, which may require macOS privacy permission (Input Monitoring).
/// If the tap can't be created, `setEnabled(true)` is a no-op.
final class PlayPauseMediaKeyInterceptor {
    private let onPlayPauseKeyDown: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var enabled = false

    init(onPlayPauseKeyDown: @escaping () -> Void) {
        self.onPlayPauseKeyDown = onPlayPauseKeyDown
    }

    deinit {
        stop()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled == self.enabled { return }
        self.enabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard eventTap == nil else {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let mask = (1 << UInt64(NX_SYSDEFINED))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Likely missing Input Monitoring permission. Best-effort: just don't intercept.
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    private func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }

        CFMachPortInvalidate(tap)
        eventTap = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard enabled else {
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == UInt32(NX_SYSDEFINED) else {
            return Unmanaged.passUnretained(event)
        }

        // Don't react to events we synthesized ourselves (used to pause/resume external playback).
        if event.getIntegerValueField(.eventSourceUserData) == MediaKeyController.eventSourceUserDataMagic {
            return Unmanaged.passUnretained(event)
        }

        guard let ns = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        // subtype 8 is NX_SUBTYPE_AUX_CONTROL_BUTTONS (media keys).
        guard ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = Int32(ns.data1)
        let keyCode = (data1 >> 16) & 0xFFFF
        let keyState = (data1 >> 8) & 0xFF

        guard keyCode == Int32(NX_KEYTYPE_PLAY) else {
            return Unmanaged.passUnretained(event)
        }

        // While we are synthesizing our own play/pause events, don't swallow them.
        // This prevents Mouth from blocking the play/pause it emits to pause/resume other apps.
        if MediaKeyController.consumePlayPausePassThroughIfNeeded(forKeyState: keyState) {
            return Unmanaged.passUnretained(event)
        }

        // 0xA is keyDown; 0xB is keyUp (matches MediaKeyController).
        if keyState == 0xA {
            onPlayPauseKeyDown()
        }

        // Swallow play/pause while enabled so other apps don't see it.
        return nil
    }

    private static let tapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let me = Unmanaged<PlayPauseMediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return me.handleEvent(type: type, event: event) ?? nil
    }
}
