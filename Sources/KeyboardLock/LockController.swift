import Carbon.HIToolbox
import Cocoa

/// Owns the CGEventTap and the locked/unlocked state machine.
///
/// The tap only watches keyboard event types (keyDown/keyUp/flagsChanged,
/// plus the undocumented "system defined" type used for the media/brightness/
/// function-key row) — mouse/trackpad events are never part of its mask, so
/// they always pass through untouched. That's what lets the user unlock via
/// a menu bar click even while the keyboard itself is fully suppressed.
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
    private var config: AppConfig = ConfigStore.load()

    // Control+Option+Command+L, used only to trigger the lock.
    private let hotkeyFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
    private let hotkeyKeyCode = Int64(kVK_ANSI_L)

    // ── Auto-lock detection ──────────────────────────────────────────────
    // Real-cat QA showed a cat's signature is less about raw speed and more
    // about *concurrency*: a paw/body presses several keys at once and holds
    // them, where human typing releases each key almost immediately (2–3
    // keys overlapping at most, even with fast rollover). Three independent
    // triggers, any one of which locks:
    //
    // 1. Paw-landing: ≥4 non-modifier keys physically held down at once.
    // 2. Cat-sitting: ≥2 keys held down concurrently for ≥1.5s. (One held
    //    key is normal human behavior — arrows, backspace — two+ isn't.)
    //    Evaluated when autorepeat events arrive, so a silent keyboard with
    //    keys pinned still gets caught as soon as repeat kicks in.
    // 3. Violent mash: ≥8 keyDowns within 0.3s spanning ≥5 distinct keys
    //    (~320 WPM instantaneous — raised from v1's ~180 after fast typing
    //    at 80–100 WPM false-triggered the old 6-in-0.4s threshold).
    private static let concurrentHeldThreshold = 4
    private static let sustainedHeldCount = 2
    private static let sustainedHeldDuration: TimeInterval = 1.5
    private static let burstWindow: TimeInterval = 0.3
    private static let burstKeyCount = 8
    private static let burstDistinctKeys = 5
    // Safety valve: a keyUp we never saw (tap briefly disabled) would leave
    // a phantom "held" key forever; drop entries older than this.
    private static let heldStaleLimit: TimeInterval = 300

    private var recentKeyDowns: [(time: TimeInterval, keyCode: Int64)] = []
    private var heldKeys: [Int64: TimeInterval] = [:]  // keyCode → time pressed

    // Keys physically down at the moment the lock engaged. Their keyDowns
    // already reached apps, so their keyUps must be allowed through too —
    // suppressing them leaves the frontmost app believing a key is still
    // held (stuck autorepeat, the accent-picker popup, post-unlock input
    // weirdness). A bare keyUp can't type anything, so passing these
    // specific releases doesn't weaken the lock.
    private var pendingReleaseKeys: Set<Int64> = []

    private init() {}

    func reloadConfig() {
        config = ConfigStore.load()
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Media/brightness/volume and most function-row keys (when not set
        // to act as literal F-keys) don't arrive as keyDown at all — macOS
        // delivers them as "system defined" events (NX_SYSDEFINED, raw type
        // 14). There's no public CGEventType case for it, but it's a stable,
        // widely-used raw value (the same trick Karabiner/Hammerspoon use).
        let systemDefinedType = CGEventType(rawValue: 14)!
        let eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, systemDefinedType]
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
        // Snapshot before the detector reset wipes heldKeys: these are the
        // keys whose downs already leaked and whose releases must follow.
        pendingReleaseKeys = Set(heldKeys.keys)
        resetDetector()
        isLocked = true
    }

    func unlock() {
        guard isLocked else { return }
        pendingReleaseKeys.removeAll()
        resetDetector()
        isLocked = false
    }

    private func resetDetector() {
        recentKeyDowns.removeAll()
        heldKeys.removeAll()
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
            // Held-key bookkeeping runs regardless of the auto-lock setting:
            // any lock (manual hotkey/menu included) needs to know which
            // keys are physically down so their releases can pass through.
            trackHeldKeys(type: type, event: event)
            if config.autoLockOnBurst, catDetected(type: type, event: event) {
                lock()
                // Swallow the triggering keystroke too — the first few of a
                // cat-mash inevitably leak before the threshold trips, but
                // there's no reason to deliver this one.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Locked: everything is suppressed except the release of a key that
        // was already down (and delivered) when the lock engaged.
        if type == .keyUp,
           pendingReleaseKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    /// Maintains the map of physically-held keys from keyDown/keyUp pairs.
    /// Modifier keys never appear here — they arrive as flagsChanged, not
    /// keyDown/keyUp — so held-key counts are already modifier-free
    /// (holding ⇧ while arrow-selecting can't contribute).
    private func trackHeldKeys(type: CGEventType, event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .keyDown:
            // Autorepeat isn't a new press — don't refresh the held
            // timestamp, or the sustained-hold clock would never advance.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                heldKeys[keyCode] = ProcessInfo.processInfo.systemUptime
            }
        case .keyUp:
            heldKeys.removeValue(forKey: keyCode)
        default:
            break
        }
    }

    /// Feeds one keyboard event into the burst window and reports whether
    /// any of the three cat signatures (paw-landing, cat-sitting, violent
    /// mash) is now present. Held-key state is maintained separately by
    /// trackHeldKeys; autorepeat keyDowns contribute no new state but act
    /// as the clock tick that lets the sustained-hold check fire while keys
    /// sit pinned under a cat.
    private func catDetected(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown else { return false }

        let now = ProcessInfo.processInfo.systemUptime
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            recentKeyDowns.append((time: now, keyCode: event.getIntegerValueField(.keyboardEventKeycode)))
        }

        recentKeyDowns.removeAll { now - $0.time > Self.burstWindow }
        heldKeys = heldKeys.filter { now - $0.value < Self.heldStaleLimit }

        // 1. Paw-landing: several keys physically down right now.
        if heldKeys.count >= Self.concurrentHeldThreshold { return true }

        // 2. Cat-sitting: multiple keys pinned for a sustained stretch.
        let sustained = heldKeys.values.filter { now - $0 >= Self.sustainedHeldDuration }
        if sustained.count >= Self.sustainedHeldCount { return true }

        // 3. Violent mash: rate + diversity beyond human typing.
        if recentKeyDowns.count >= Self.burstKeyCount,
           Set(recentKeyDowns.map(\.keyCode)).count >= Self.burstDistinctKeys {
            return true
        }

        return false
    }

    private func matchesHotkey(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkeyKeyCode else { return false }
        let relevantFlags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return relevantFlags == hotkeyFlags
    }
}
