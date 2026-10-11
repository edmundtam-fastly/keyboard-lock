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

    // Auto-lock detection thresholds and decision rules live in LockLogic
    // (pure and unit-tested); this class only maintains the event-driven
    // state they evaluate.
    private var recentKeyDowns: [(time: TimeInterval, keyCode: Int64)] = []
    private var heldKeys: [Int64: TimeInterval] = [:]  // keyCode → time pressed

    // Keys physically down at the moment the lock engaged. Their keyDowns
    // already reached apps, so their keyUps must be allowed through too —
    // suppressing them leaves the frontmost app believing a key is still
    // held (stuck autorepeat, the accent-picker popup, post-unlock input
    // weirdness). A bare keyUp can't type anything, so passing these
    // specific releases doesn't weaken the lock.
    private var pendingReleaseKeys: Set<Int64> = []

    // Same idea for modifier keys, which arrive as flagsChanged instead of
    // keyDown/keyUp: tracked modifiers physically held when the lock
    // engaged. Their releases drain through (per LockLogic's decision rule)
    // so a leaked Fn/Globe or the lock hotkey's own ⌃⌥⌘ can't stay stuck —
    // a stuck Fn turns "e" into the emoji picker after unlocking.
    private var pendingReleaseFlags: CGEventFlags = []

    // Drives the time-based cat-sitting check when no events are arriving.
    private static let idleSittingPollInterval: TimeInterval = 0.5
    private var idleSittingTimer: Timer?

    private init() {}

    func reloadConfig() {
        config = ConfigStore.load()
        updateIdleSittingTimer()
    }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        // Media/brightness/volume and most function-row keys (when not set
        // to act as literal F-keys) don't arrive as keyDown at all — macOS
        // delivers them as "system defined" events (NX_SYSDEFINED, raw type
        // 14). There's no public CGEventType case for it, but it's a stable,
        // widely-used raw value (the same trick Karabiner/Hammerspoon use).
        var eventTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        if let systemDefinedType = CGEventType(rawValue: 14) {
            eventTypes.append(systemDefinedType)
        } else {
            NSLog("KeyboardLock: system-defined event type unavailable; media/function-row keys will not be suppressed")
        }
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
        // Modifiers don't go through keyDown/keyUp, so read their physical
        // state straight from the HID system: whatever is held right now
        // was already delivered as a press and needs its release drained.
        pendingReleaseFlags = CGEventSource.flagsState(.hidSystemState)
            .intersection(LockLogic.trackedModifierFlags)
        if !pendingReleaseFlags.isEmpty {
            NSLog("KeyboardLock: locked with %d modifier flag(s) held; their releases will pass through", pendingReleaseFlags.rawValue.nonzeroBitCount)
        }
        resetDetector()
        isLocked = true
    }

    func unlock() {
        guard isLocked else { return }
        pendingReleaseKeys.removeAll()
        pendingReleaseFlags = []
        resetDetector()
        isLocked = false
    }

    private func resetDetector() {
        recentKeyDowns.removeAll()
        heldKeys.removeAll()
        updateIdleSittingTimer()
    }

    /// Drops held-key entries whose keys aren't actually depressed any more,
    /// asking the HID system rather than guessing. Used after the tap was
    /// disabled, when keyUps may have been missed entirely.
    private func reconcileHeldKeysWithHardware() {
        heldKeys = heldKeys.filter { entry in
            guard let code = CGKeyCode(exactly: entry.key) else { return false }
            return CGEventSource.keyState(.hidSystemState, key: code)
        }
        updateIdleSittingTimer()
    }

    /// The cat-sitting rule is time-based, but events are the only thing
    /// that normally drives evaluation — so two keys pinned under a sleeping
    /// cat are invisible until some other key is pressed. Autorepeat usually
    /// provides that tick, but a user who has turned key repeat off in
    /// System Settings would never get one. This low-frequency poll runs
    /// only while auto-lock is armed and keys are actually held, so it costs
    /// nothing in the common idle case.
    private func updateIdleSittingTimer() {
        let needed = config.autoLockOnBurst && !isLocked && !heldKeys.isEmpty
        if needed, idleSittingTimer == nil {
            let timer = Timer(timeInterval: Self.idleSittingPollInterval, repeats: true) { [weak self] _ in
                self?.evaluateHeldKeysWhileIdle()
            }
            // .common so an open menu bar menu doesn't starve the timer.
            RunLoop.main.add(timer, forMode: .common)
            idleSittingTimer = timer
        } else if !needed, let timer = idleSittingTimer {
            timer.invalidate()
            idleSittingTimer = nil
        }
    }

    private func evaluateHeldKeysWhileIdle() {
        let now = ProcessInfo.processInfo.systemUptime
        heldKeys = LockLogic.pruneHeldKeys(heldKeys, now: now)
        recentKeyDowns.removeAll { now - $0.time > LockLogic.burstWindow }

        if config.autoLockOnBurst, !isLocked,
           let trigger = LockLogic.catTrigger(heldKeys: heldKeys, recentKeyDowns: recentKeyDowns, now: now) {
            NSLog("KeyboardLock: auto-lock fired (idle poll) — %@", trigger)
            lock()
            return
        }
        updateIdleSittingTimer()
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
            // Events went missing while the tap was deaf, so the detector's
            // view of the keyboard is stale: any keyUp we failed to see left
            // a phantom held key that could fake a paw-landing. Rather than
            // blanket-reset (which would lose genuinely-held keys), re-probe
            // the hardware for the truth.
            reconcileHeldKeysWithHardware()
            recentKeyDowns.removeAll()
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
            if config.autoLockOnBurst, let trigger = catDetected(type: type, event: event) {
                // Rule name + counts only — never key identities — so false
                // positives can be diagnosed from Console/log show.
                NSLog("KeyboardLock: auto-lock fired — %@", trigger)
                lock()
                // Swallow the triggering keystroke too — the first few of a
                // cat-mash inevitably leak before the threshold trips, but
                // there's no reason to deliver this one.
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Locked: everything is suppressed except events that *close out*
        // state apps already saw — the release of a key or modifier that was
        // down (and delivered) when the lock engaged. Releases type nothing,
        // so the lock isn't weakened.
        switch type {
        case .keyUp:
            if pendingReleaseKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil {
                return Unmanaged.passUnretained(event)
            }
        case .flagsChanged:
            if let shrunk = LockLogic.modifierReleaseDecision(eventFlags: event.flags, pending: pendingReleaseFlags) {
                pendingReleaseFlags = shrunk
                return Unmanaged.passUnretained(event)
            }
        default:
            break
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
        // Prune phantoms (missed keyUps) unconditionally, not just when the
        // auto-lock detector runs — they'd otherwise inflate concurrency
        // counts and pollute the pendingReleaseKeys snapshot at lock time.
        heldKeys = LockLogic.pruneHeldKeys(heldKeys, now: ProcessInfo.processInfo.systemUptime)
        updateIdleSittingTimer()
    }

    /// Feeds one keyboard event into the burst window and asks LockLogic
    /// whether any cat signature (paw-landing, cat-sitting, violent mash)
    /// is now present, returning its description or nil. Held-key state is
    /// maintained separately by trackHeldKeys; autorepeat keyDowns
    /// contribute no new state but act as the clock tick that lets the
    /// sustained-hold check fire while keys sit pinned under a cat.
    private func catDetected(type: CGEventType, event: CGEvent) -> String? {
        guard type == .keyDown else { return nil }

        let now = ProcessInfo.processInfo.systemUptime
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            recentKeyDowns.append((time: now, keyCode: event.getIntegerValueField(.keyboardEventKeycode)))
        }
        recentKeyDowns.removeAll { now - $0.time > LockLogic.burstWindow }

        return LockLogic.catTrigger(heldKeys: heldKeys, recentKeyDowns: recentKeyDowns, now: now)
    }

    private func matchesHotkey(event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == hotkeyKeyCode else { return false }
        let relevantFlags = event.flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        return relevantFlags == hotkeyFlags
    }
}
