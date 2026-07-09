import Carbon.HIToolbox
import Cocoa

/// Owns the CGEventTap and the locked/unlocked state machine.
///
/// The tap only watches keyboard event types (keyDown/keyUp/flagsChanged) —
/// mouse/trackpad events are never part of its mask, so they always pass
/// through untouched. That's what lets the user unlock via a menu bar click
/// even while the keyboard itself is fully suppressed.
final class LockController {
    static let shared = LockController()

    private(set) var isLocked = false {
        didSet {
            guard oldValue != isLocked else { return }
            onStateChange?(isLocked)
        }
    }
    var onStateChange: ((Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Control+Option+Command+L, used only to trigger the lock.
    private let hotkeyFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    private let hotkeyKeyCode = Int64(kVK_ANSI_L)

    private init() {}

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask: CGEventMask = 0
        for eventType in eventTypes {
            let bit: CGEventMask = 1 << eventType.rawValue
            mask |= bit
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<LockController>.fromOpaque(userInfo).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Tears the tap down cleanly. Also happens implicitly if this process
    /// dies/crashes: the kernel owns the tap by client PID and releases it
    /// with the process, so a crash while locked can never leave the OS
    /// keyboard permanently suppressed.
    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func lock() {
        guard !isLocked else { return }
        isLocked = true
    }

    func unlock() {
        guard isLocked else { return }
        isLocked = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS can disable a tap if our callback is too slow, or if the
        // user disables it from Accessibility settings. Re-enable immediately
        // so we fail toward "still working" rather than silently going deaf
        // and leaving stale suppression state.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if !isLocked {
            if type == .keyDown, matchesHotkey(event: event) {
                lock()
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        return nil
    }

    private func matchesHotkey(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkeyKeyCode else { return false }
        let relevantFlags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return relevantFlags == hotkeyFlags
    }
}
