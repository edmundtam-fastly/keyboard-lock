import CoreGraphics
import XCTest

@testable import KeyboardLock

// ─── Modifier release machine ────────────────────────────────────────────
//
// These tests map the stuck-modifier error states directly: each one names
// the real-world symptom it prevents. The machine's contract: while locked,
// a flagsChanged event passes only if it purely releases modifiers that
// were held when the lock engaged — never if it presses anything new.
final class ModifierReleaseTests: XCTestCase {

    // Error state: stuck Fn/Globe → pressing "e" opens the emoji picker,
    // arrows become page-jumps, delete becomes forward-delete.
    func testStuckFnGlobeReleaseDrains() {
        let pending: CGEventFlags = [.maskSecondaryFn]
        let result = LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending)
        XCTAssertNotNil(result, "Fn release must pass through or Fn stays stuck (emoji picker on 'e')")
        XCTAssertEqual(result, [])
    }

    // Error state: the lock hotkey poisoning itself — ⌃⌥⌘ held at lock
    // time, releases swallowed → letters become menu shortcuts after
    // unlock (⌘Q quits apps, ⌘W closes windows, ⌘A+type destroys text).
    func testHotkeyModifiersDrainOneByOne() {
        var pending: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

        // Release Cmd first.
        var next = LockLogic.modifierReleaseDecision(
            eventFlags: [.maskControl, .maskAlternate], pending: pending)
        XCTAssertEqual(next, [.maskControl, .maskAlternate])
        pending = next!

        // Then Ctrl.
        next = LockLogic.modifierReleaseDecision(eventFlags: [.maskAlternate], pending: pending)
        XCTAssertEqual(next, [.maskAlternate])
        pending = next!

        // Then Opt.
        next = LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending)
        XCTAssertEqual(next, [])
    }

    func testAllModifiersReleasedAtOnceDrains() {
        let pending: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertEqual(LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending), [])
    }

    // Error state guarded against: a modifier PRESS escaping the lock. A
    // Globe press is itself the emoji trigger; a ⌘ press would arm every
    // letter the cat hits next. Presses must stay swallowed even while
    // releases are draining.
    func testNewModifierPressWhileLockedIsSuppressed() {
        let pending: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        let withShift: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: withShift, pending: pending),
                     "a new modifier press must never escape the lock")
    }

    // Error state guarded against: release+press in one event (cat rolls
    // from Shift onto Cmd). Not a pure release → suppressed.
    func testSwapReleaseAndPressIsSuppressed() {
        XCTAssertNil(LockLogic.modifierReleaseDecision(
            eventFlags: [.maskCommand], pending: [.maskShift]))
    }

    func testNothingPendingSuppressesEverything() {
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: [.maskSecondaryFn], pending: []),
                     "Fn press with nothing pending must be suppressed")
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: [], pending: []),
                     "no-op flags event must be suppressed")
    }

    // Exactly-once semantics: once a pending modifier drains, a cat
    // re-pressing and re-releasing it while locked leaks nothing.
    func testDrainIsExactlyOnce() {
        var pending: CGEventFlags = [.maskSecondaryFn]

        // Release: passes, pending empties.
        pending = LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending)!

        // Cat presses Fn again: suppressed (press).
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: [.maskSecondaryFn], pending: pending))

        // Cat releases it: suppressed (equal to pending — the press was
        // never delivered, so no release is owed).
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending))
    }

    // Caps Lock is a toggle, not a hold — untracked by design. Its
    // flagsChanged must not be mistaken for a release of pending flags.
    func testCapsLockToggleIsIgnored() {
        let pending: CGEventFlags = [.maskSecondaryFn]
        XCTAssertNil(LockLogic.modifierReleaseDecision(
            eventFlags: [.maskSecondaryFn, .maskAlphaShift], pending: pending),
            "caps toggle changes no tracked flag — suppress")
    }

    // Documented residual: pending Shift, cat presses Ctrl, user releases
    // Shift while Ctrl is still down. That event isn't a pure release
    // (it announces an undelivered Ctrl), so it's suppressed — and the
    // machine self-heals when the cat lets go of Ctrl.
    func testBlockedReleaseSelfHealsWhenIntruderLifts() {
        let pending: CGEventFlags = [.maskShift]

        // Shift release while cat holds Ctrl: suppressed.
        XCTAssertNil(LockLogic.modifierReleaseDecision(eventFlags: [.maskControl], pending: pending))

        // Cat lifts Ctrl → flags now empty → pure release of Shift → passes.
        XCTAssertEqual(LockLogic.modifierReleaseDecision(eventFlags: [], pending: pending), [])
    }
}

// ─── Auto-lock trigger rules ─────────────────────────────────────────────
final class CatTriggerTests: XCTestCase {

    private func held(_ entries: [(Int64, TimeInterval)]) -> [Int64: TimeInterval] {
        Dictionary(uniqueKeysWithValues: entries)
    }

    func testPawLandingFiresAtFourConcurrentKeys() {
        let now: TimeInterval = 100
        let keys = held([(1, 99.9), (2, 99.9), (3, 99.9), (4, 99.9)])
        XCTAssertNotNil(LockLogic.catTrigger(heldKeys: keys, recentKeyDowns: [], now: now))
    }

    func testThreeConcurrentKeysDoNotFire() {
        let now: TimeInterval = 100
        let keys = held([(1, 99.9), (2, 99.9), (3, 99.9)])
        XCTAssertNil(LockLogic.catTrigger(heldKeys: keys, recentKeyDowns: [], now: now))
    }

    func testCatSittingFiresForTwoKeysPinned() {
        let now: TimeInterval = 100
        let keys = held([(1, 98.0), (2, 98.2)])  // held 2.0s and 1.8s
        XCTAssertNotNil(LockLogic.catTrigger(heldKeys: keys, recentKeyDowns: [], now: now))
    }

    func testTwoBrieflyOverlappingKeysDoNotFire() {
        let now: TimeInterval = 100
        let keys = held([(1, 99.9), (2, 99.95)])  // typing rollover
        XCTAssertNil(LockLogic.catTrigger(heldKeys: keys, recentKeyDowns: [], now: now))
    }

    // Holding one key is human (backspace, arrows, gaming) — never a trigger.
    func testSingleLongHeldKeyDoesNotFire() {
        let now: TimeInterval = 100
        let keys = held([(1, 95.0)])  // held 5s
        XCTAssertNil(LockLogic.catTrigger(heldKeys: keys, recentKeyDowns: [], now: now))
    }

    func testViolentMashFires() {
        let now: TimeInterval = 100
        var downs: [(time: TimeInterval, keyCode: Int64)] = []
        for i in 0..<8 {
            let time: TimeInterval = now - 0.25 + Double(i) * 0.03
            downs.append((time: time, keyCode: Int64(i % 6)))
        }
        XCTAssertNotNil(LockLogic.catTrigger(heldKeys: [:], recentKeyDowns: downs, now: now))
    }

    // Two-key drumming (or a game's alternating keys): high rate, low
    // diversity — must not fire.
    func testLowDiversityBurstDoesNotFire() {
        let now: TimeInterval = 100
        var downs: [(time: TimeInterval, keyCode: Int64)] = []
        for i in 0..<10 {
            let time: TimeInterval = now - 0.28 + Double(i) * 0.028
            downs.append((time: time, keyCode: Int64(i % 2)))
        }
        XCTAssertNil(LockLogic.catTrigger(heldKeys: [:], recentKeyDowns: downs, now: now))
    }

    func testPhantomHeldKeysArePruned() {
        let now: TimeInterval = 100
        let keys = held([(1, now - 11), (2, now - 9)])
        let pruned = LockLogic.pruneHeldKeys(keys, now: now)
        XCTAssertEqual(Set(pruned.keys), [2], "entries past the stale limit must drop")
    }

    // Phantom accumulation scenario: 3 stale phantoms (missed keyUps) plus
    // one real keystroke used to satisfy paw-landing's 4-concurrent rule.
    // With pruning they must not.
    func testPhantomsCannotFakeAPawLanding() {
        let now: TimeInterval = 100
        let phantoms = held([(1, now - 30), (2, now - 25), (3, now - 15), (4, now - 0.01)])
        let pruned = LockLogic.pruneHeldKeys(phantoms, now: now)
        XCTAssertNil(LockLogic.catTrigger(heldKeys: pruned, recentKeyDowns: [], now: now))
    }
}

// ─── Simulated typing traces ─────────────────────────────────────────────
//
// End-to-end runs of the detector state machine against generated input
// streams, mirroring exactly what LockController feeds LockLogic.
final class TypingTraceTests: XCTestCase {

    private struct SimEvent {
        let time: TimeInterval
        let keyCode: Int64
        let isDown: Bool
    }

    /// Replays a trace through the same bookkeeping the controller does,
    /// returning the first trigger description or nil.
    private func runTrace(_ events: [SimEvent]) -> String? {
        var heldKeys: [Int64: TimeInterval] = [:]
        var recent: [(time: TimeInterval, keyCode: Int64)] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if event.isDown {
                heldKeys[event.keyCode] = event.time
                recent.append((time: event.time, keyCode: event.keyCode))
            } else {
                heldKeys.removeValue(forKey: event.keyCode)
            }
            heldKeys = LockLogic.pruneHeldKeys(heldKeys, now: event.time)
            recent.removeAll { event.time - $0.time > LockLogic.burstWindow }
            if event.isDown,
               let trigger = LockLogic.catTrigger(heldKeys: heldKeys, recentKeyDowns: recent, now: event.time) {
                return trigger
            }
        }
        return nil
    }

    /// Rollover typing: each key pressed `interval` apart and held past the
    /// next key's press, the way fast typists overlap keystrokes. Shift held
    /// for caps never appears here — modifiers aren't keyDown events — so
    /// this trace equally models caps-lock or shift-held fast typing.
    private func typingTrace(keysPerSecond: Double, holdSeconds: Double, count: Int) -> [SimEvent] {
        let interval = 1.0 / keysPerSecond
        var events: [SimEvent] = []
        for i in 0..<count {
            let code = Int64(i % 12)
            let down = 10.0 + Double(i) * interval
            events.append(SimEvent(time: down, keyCode: code, isDown: true))
            events.append(SimEvent(time: down + holdSeconds, keyCode: code, isDown: false))
        }
        return events
    }

    // ~110 WPM sustained with heavy rollover (keys held 40% past the next
    // press). This is the "typing quickly with caps" profile — must not lock.
    func testFastRolloverTypingDoesNotTrigger() {
        let trace = typingTrace(keysPerSecond: 9.2, holdSeconds: 0.15, count: 120)
        XCTAssertNil(runTrace(trace), "sustained 110 WPM rollover typing must not auto-lock")
    }

    // Burst clusters: real typing isn't uniform — familiar words come out
    // as rapid clusters. Six keys in ~0.2s then a pause, repeated.
    func testBurstyWordClustersDoNotTrigger() {
        var events: [SimEvent] = []
        for word in 0..<10 {
            let start = 10.0 + Double(word) * 0.9
            for i in 0..<6 {
                let code = Int64((word * 6 + i) % 12)
                let down = start + Double(i) * 0.035
                events.append(SimEvent(time: down, keyCode: code, isDown: true))
                events.append(SimEvent(time: down + 0.08, keyCode: code, isDown: false))
            }
        }
        XCTAssertNil(runTrace(events), "word-burst clusters must not auto-lock")
    }

    // A cat landing: five keys pressed nearly at once and held.
    func testSimulatedPawLandingTriggers() {
        var events: [SimEvent] = []
        for i in 0..<5 {
            events.append(SimEvent(time: 10.0 + Double(i) * 0.015, keyCode: Int64(i), isDown: true))
        }
        XCTAssertNotNil(runTrace(events), "a five-key paw landing must auto-lock")
    }

    // A cat settling: two keys pinned while the keyboard otherwise idles;
    // detection fires on the next evaluation tick (autorepeat in real use —
    // modeled here as a later keyDown of a third key).
    func testSimulatedCatSittingTriggers() {
        let events = [
            SimEvent(time: 10.0, keyCode: 1, isDown: true),
            SimEvent(time: 10.1, keyCode: 2, isDown: true),
            SimEvent(time: 12.0, keyCode: 3, isDown: true),  // evaluation tick
        ]
        XCTAssertNotNil(runTrace(events), "two keys pinned for 1.9s must auto-lock")
    }
}
