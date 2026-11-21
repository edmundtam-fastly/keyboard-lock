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
    // 2. Cat-sitting: keys pinned for ≥1.5s, in two tiers (see below).
    // 3. Violent mash: ≥8 keyDowns within 0.3s spanning ≥5 distinct keys
    //    (~320 WPM instantaneous — raised after real fast typing at
    //    80–100 WPM false-triggered a lower threshold).
    static let concurrentHeldThreshold = 4
    static let sustainedHeldDuration: TimeInterval = 1.5
    static let burstWindow: TimeInterval = 0.3
    static let burstKeyCount = 8
    static let burstDistinctKeys = 5

    // Cat-sitting tiers. Holding two keys for seconds is NOT automatically
    // feline: W+A to strafe in a game is exactly that, deliberately, for
    // minutes. What separates a cat is *co-arrival* — a paw or flank is one
    // physical event, so its keys depress within milliseconds of each other,
    // while a human adds the second key as a separate decision hundreds of
    // milliseconds or seconds later.
    //
    //   • exactly 2 pinned keys  → also require they landed together
    //   • 3+ pinned keys         → trigger regardless of arrival timing
    //     (holding three non-modifier keys for 1.5s+ has no common human
    //     analogue, and it covers a cat that settles progressively)
    static let sustainedHeldCount = 2
    static let sustainedHeldCountIgnoringArrival = 3
    static let sustainedCoArrivalWindow: TimeInterval = 0.12

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

    /// Everything the rules consider, reduced to numbers. Note what is
    /// absent: key identity. Only *how many* distinct keys appear, never
    /// which — which is why the calibration log can record these verbatim
    /// without capturing anything that was typed.
    struct Measurements {
        var heldCount: Int = 0
        var heldSpread: TimeInterval = 0     // arrival spread, all held keys
        var maxHold: TimeInterval = 0        // longest current hold
        var pinnedCount: Int = 0             // held past sustainedHeldDuration
        var pinnedSpread: TimeInterval = 0   // arrival spread, pinned keys
        var windowDowns: Int = 0
        var windowDistinct: Int = 0
    }

    static func measure(
        heldKeys: [Int64: TimeInterval],
        recentKeyDowns: [(time: TimeInterval, keyCode: Int64)],
        now: TimeInterval
    ) -> Measurements {
        var m = Measurements()
        m.heldCount = heldKeys.count

        let pressTimes = heldKeys.values.sorted()
        if let earliest = pressTimes.first, let latest = pressTimes.last {
            m.heldSpread = latest - earliest
            m.maxHold = now - earliest
        }

        let pinned = pressTimes.filter { now - $0 >= sustainedHeldDuration }
        m.pinnedCount = pinned.count
        if let first = pinned.first, let last = pinned.last {
            m.pinnedSpread = last - first
        }

        m.windowDowns = recentKeyDowns.count
        m.windowDistinct = Set(recentKeyDowns.map(\.keyCode)).count
        return m
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
        catTrigger(measure(heldKeys: heldKeys, recentKeyDowns: recentKeyDowns, now: now))
    }

    static func catTrigger(_ m: Measurements) -> String? {
        if m.heldCount >= concurrentHeldThreshold {
            return "paw-landing: \(m.heldCount) keys held concurrently"
        }

        if m.pinnedCount > 0 {
            let oldest = String(format: "%.1fs", m.maxHold)
            if m.pinnedCount >= sustainedHeldCountIgnoringArrival {
                return "cat-sitting: \(m.pinnedCount) keys held, oldest \(oldest)"
            }
            // Exactly 2 pinned keys: only feline if they landed together.
            // A deliberate human second press (strafing, chorded shortcuts)
            // arrives far later than one paw hitting both at once.
            if m.pinnedCount >= sustainedHeldCount, m.pinnedSpread <= sustainedCoArrivalWindow {
                let spread = String(format: "%.0fms", m.pinnedSpread * 1000)
                return "cat-sitting: 2 keys landed together (\(spread) apart), held \(oldest)"
            }
        }

        if m.windowDowns >= burstKeyCount, m.windowDistinct >= burstDistinctKeys {
            return "violent-mash: \(m.windowDowns) keyDowns (\(m.windowDistinct) distinct) in \(burstWindow)s"
        }

        return nil
    }
}
