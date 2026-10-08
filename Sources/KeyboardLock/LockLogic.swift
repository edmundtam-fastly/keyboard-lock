import CoreGraphics
import Foundation

/// Pure decision logic for the lock — no CGEventTap, AppKit, or singleton
/// state — so every rule here is directly unit-testable (see
/// Tests/KeyboardLockTests).
enum LockLogic {
    // ── Auto-lock thresholds ─────────────────────────────────────────────
    // A cat's signature is concurrency and hold duration more than raw
    // speed: a paw/body presses several keys at once and holds them, where
    // human typing releases each key almost immediately (2–3 overlapping at
    // most, even with fast rollover). Three independent triggers, any one
    // of which locks:
    //
    // 1. Paw-landing: ≥4 non-modifier keys physically held down at once.
    // 2. Cat-sitting: ≥2 keys held down concurrently for ≥1.5s. (One held
    //    key is normal human behavior — arrows, backspace — two+ isn't.)
    //    Evaluated when autorepeat events arrive, so a silent keyboard with
    //    keys pinned still gets caught as soon as repeat kicks in.
    // 3. Violent mash: ≥8 keyDowns within 0.3s spanning ≥5 distinct keys
    //    (~320 WPM instantaneous — raised after real fast typing at
    //    80–100 WPM false-triggered a lower threshold).
    static let concurrentHeldThreshold = 4
    static let sustainedHeldCount = 2
    static let sustainedHeldDuration: TimeInterval = 1.5
    static let burstWindow: TimeInterval = 0.3
    static let burstKeyCount = 8
    static let burstDistinctKeys = 5

    // Safety valve: a keyUp we never saw (tap briefly disabled, secure
    // input fields swallowing events mid-pair) leaves a phantom "held" key
    // that inflates the concurrency counts and causes false auto-locks.
    // Real pinned keys that matter are caught by cat-sitting at 1.5s, so
    // aging entries out at 10s costs no detection.
    static let heldStaleLimit: TimeInterval = 10

    /// Modifier flags whose press/release state the lock tracks. Caps Lock
    /// (.maskAlphaShift) is deliberately absent: it's a toggle, not a hold,
    /// so there is no "release" to drain.
    static let trackedModifierFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ]

    /// Decides whether a flagsChanged event arriving while locked may pass
    /// through. `pending` is the set of tracked modifiers physically held
    /// when the lock engaged: their presses already reached apps, so their
    /// releases must follow or apps are left believing a modifier is still
    /// held (stuck Fn/Globe turns "e" into the emoji picker, stuck ⌘ turns
    /// letters into menu shortcuts).
    ///
    /// Returns the shrunken pending set when the event is a pure release of
    /// pending modifiers (pass it through, exactly once per flag); nil means
    /// suppress. Anything that presses a new modifier — or changes nothing
    /// we track — stays swallowed: a Globe *press* is itself the
    /// emoji-picker trigger, so only releases may escape the lock.
    static func modifierReleaseDecision(eventFlags: CGEventFlags, pending: CGEventFlags) -> CGEventFlags? {
        let newTracked = eventFlags.intersection(trackedModifierFlags)
        guard newTracked != pending, pending.isSuperset(of: newTracked) else { return nil }
        return newTracked
    }

    /// Drops phantom held-key entries older than the stale limit.
    static func pruneHeldKeys(_ heldKeys: [Int64: TimeInterval], now: TimeInterval) -> [Int64: TimeInterval] {
        heldKeys.filter { now - $0.value < heldStaleLimit }
    }

    /// Evaluates the three cat signatures against current detector state.
    /// Returns a human-readable trigger description (used for the unified-
    /// log diagnostic, so false positives can be traced to a specific rule
    /// and its counts), or nil when nothing fires.
    static func catTrigger(
        heldKeys: [Int64: TimeInterval],
        recentKeyDowns: [(time: TimeInterval, keyCode: Int64)],
        now: TimeInterval
    ) -> String? {
        if heldKeys.count >= concurrentHeldThreshold {
            return "paw-landing: \(heldKeys.count) keys held concurrently"
        }

        let sustainedAges = heldKeys.values.map { now - $0 }.filter { $0 >= sustainedHeldDuration }
        if sustainedAges.count >= sustainedHeldCount {
            let oldest = sustainedAges.max().map { String(format: "%.1fs", $0) } ?? "?"
            return "cat-sitting: \(sustainedAges.count) keys held, oldest \(oldest)"
        }

        let distinct = Set(recentKeyDowns.map(\.keyCode)).count
        if recentKeyDowns.count >= burstKeyCount, distinct >= burstDistinctKeys {
            return "violent-mash: \(recentKeyDowns.count) keyDowns (\(distinct) distinct) in \(burstWindow)s"
        }

        return nil
    }
}
