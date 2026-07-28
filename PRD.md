# PRD: Cat-Proof Keyboard Lock

**Status:** v1 shipped, v1.1 in progress **Platform:** macOS **Owner:** Edmund **Last updated:** 2026-07-23

> Revision note: this PRD was updated after v1 shipped to reflect what was
> actually built (see §5a for deltas from the original draft) and to spec the
> v1.1 burst auto-lock feature (§5b).

---

## 1. Problem

During Zoom meetings, a user's cat frequently jumps onto the keyboard, causing unintended keystrokes (muting/unmuting, triggering shortcuts, typing garbage into chat, etc.). The user needs a way to disable keyboard input temporarily without ending the meeting, losing video/audio, or disrupting their active work session (open apps, unsaved work, etc.).

## 2. User Story

As a cat parent, I want to lock my keyboard during Zoom meetings so my cat can't disrupt the call or my open apps, but I still want to be visible/audible in the meeting and have my session stay active. I want to unlock it easily when I'm ready — and ideally, the lock should also kick in on its own when the cat strikes before I can react.

## 3. Goals

- Toggle keyboard lock on/off via a simple trigger (hotkey and menu bar click)
- While locked, **all keyboard input is suppressed system-wide** — no app receives keystrokes, including the function/media/brightness row
- Trackpad and mouse stay fully live at all times, so unlocking is always one click away
- Camera and microphone remain fully functional while locked (Zoom stays unaffected)
- Clear visual indicator when lock is active (menu bar icon state + on-screen banner)
- Lock survives across the duration of a meeting (no timeout)
- **(v1.1)** Optionally auto-lock when a burst of keystrokes consistent with a cat landing on the keyboard is detected

## 4. Non-Goals

- This is **not** a security/access-control tool — it should not be relied on to prevent a human from using the computer. It's a convenience feature against an actual cat.
- No multi-user support, no remote/cloud config
- No Windows/Linux support (macOS only)
- No camera/ML-based cat detection — keystroke signal is sufficient, and camera access would conflict with the minimal-permissions goal

## 5. Functional Requirements (as shipped in v1)

| # | Requirement |
| :---- | :---- |
| 1 | User can trigger "lock keyboard" via global hotkey (`⌃⌥⌘L`) or menu bar item |
| 2 | Once locked, all keyboard events (keyDown/keyUp/flagsChanged, plus system-defined media/function-row events) are intercepted and discarded before reaching any application |
| 3 | Trackpad/mouse events are never intercepted — they stay fully live while locked |
| 4 | Unlock via menu bar item ("Unlock Keyboard") restores keyboard function immediately |
| 5 | Menu bar icon changes state (open/filled lock) to show current status |
| 6 | Transparent on-screen banner while locked: "Keyboard Locked — Unlock in menu dropdown" (click-through, doesn't obscure content) |
| 7 | App launches at login (optional setting, off by default) |
| 8 | Hard restart of the machine always unlocks |
| 9 | If the app crashes or is killed while locked, the OS tears the event tap down with the process — a stuck lock is impossible |

### 5a. Deltas from the original draft

- **Typed unlock code (orig. FR3–FR5, FR8) was dropped.** In real-world testing the rolling-buffer code match was unreliable and once left the keyboard stuck locked. Because the trackpad is never suppressed, a menu click is a strictly simpler and more reliable unlock path, with nothing to remember or mistype.
- **Trackpad suppression (orig. FR2) was inverted.** The original draft required trackpad events to be suppressed but also relied on mouse clicks as the forgot-the-code fallback — mutually inconsistent under a single CGEventTap. v1 keeps pointer input live by design.

### 5b. v1.1: Auto-lock on cat-like input (revised after real-cat QA)

> The first-pass detector was rate-only (≥6 keyDowns in 0.4s, ≥4 distinct
> keys) and failed both ways in testing: fast human typing at 80–100 WPM
> false-triggered it, while the cat's actual landing — a few keys pressed
> *simultaneously and held*, not a rapid sequence — didn't trip it at all.
> The revised detector treats **concurrency and hold duration** as the
> primary cat signatures, with raw rate demoted to a backstop.

| # | Requirement |
| :---- | :---- |
| 10 | User can enable "Auto-Lock on Key Burst" via a menu bar toggle; **off by default** (the original draft explicitly declined always-on auto-lock, so this is strictly opt-in) |
| 11 | **Paw-landing trigger:** ≥4 non-modifier keys physically held down at the same moment locks immediately (human rollover typing overlaps 2–3 keys at most) |
| 12 | **Cat-sitting trigger:** ≥2 keys held down concurrently for ≥1.5s locks (one held key is normal human behavior — arrows, backspace — two-plus is not) |
| 13 | **Mash backstop:** ≥8 keyDowns within 0.3s spanning ≥5 distinct keycodes (~320 WPM instantaneous, comfortably above the ~100 WPM false-trigger point observed with the old threshold) |
| 14 | Auto-repeat from held keys never counts as new presses, but serves as the clock tick that lets the sitting trigger fire while keys sit pinned |
| 15 | Modifier keys (⇧⌃⌥⌘/fn) never count toward held-key totals — holding Shift while arrow-selecting text cannot contribute to a trigger |
| 16 | The keystroke that trips a threshold is itself suppressed; keystrokes before it necessarily pass through (accepted limitation — detection requires evidence) |
| 17 | Setting persists across app restarts (stored in local config alongside launch-at-login) |

**Known tuning caveats:** thresholds remain compile-time constants in
`LockController` pending further real-cat evidence. A cat sitting on exactly
one key is indistinguishable from a human holding backspace and deliberately
does not trigger.

## 6. Non-Functional Requirements

- **Fail-safe:** if the app crashes while locked, the keyboard must not remain locked (satisfied structurally: the kernel releases the event tap with the process)
- **Low latency:** no perceptible input lag when unlocked/normal
- **No network access** — fully local, no data leaves the machine
- **Minimal permissions footprint:** only Accessibility + Input Monitoring

## 7. Technical Approach (macOS)

- **CGEventTap** (Swift + Quartz) at the session level, head-insert, intercepting `keyDown`/`keyUp`/`flagsChanged` plus raw event type 14 (`NX_SYSDEFINED`) for the media/function-key row
- Menu bar app via `NSStatusItem` (AppKit, `LSUIElement`, no Dock icon)
- Burst detection: rolling array of (timestamp, keycode) pairs pruned to the detection window on each keyDown; O(window size) per event, negligible latency
- Config stored at `~/Library/Application Support/KeyboardLock/config.json`
- Signed with a persistent local self-signed identity so TCC permission grants survive rebuilds
- Launch-at-login via per-user LaunchAgent plist

## 8. UX Flow

1. User clicks menu bar icon or presses `⌃⌥⌘L` → keyboard locks, icon/banner update — **or**, with Auto-Lock enabled, the cat's own keystroke burst triggers the lock
2. Cat mashes keyboard → nothing (further) happens in any app
3. User clicks menu bar icon → "Unlock Keyboard" → keyboard restored, icon/banner update

## 9. Edge Cases

- Cat holds down keys (auto-repeat): suppressed while locked; while unlocked, repeats aren't counted as new presses but do drive the cat-sitting duration check
- Fast human typing burst (validated to ~100 WPM real-world): must not false-trigger auto-lock — concurrency triggers require physically overlapping held keys that typing doesn't produce, and the rate backstop sits at ~320 WPM instantaneous
- Human holding one key (backspace, arrows, gaming): a single held key never triggers; two-plus held keys for 1.5s does
- Key already down when the lock engages (common with auto-lock — the leaked pre-threshold keyDowns): its keyUp is allowed through once so the frontmost app doesn't perceive a stuck held key (macOS accent-picker popup, post-unlock input weirdness); a bare keyUp types nothing, so suppression isn't weakened. Modifier keys held at lock time (flagsChanged) are not covered — deferred until observed in practice
- App killed/crashed while locked: event tap dies with the process, input restored automatically
- System-reserved shortcuts (⌘Tab, Spotlight, Mission Control): intercepted by macOS above any third-party tap; cannot be blocked (documented limitation)
- Caps Lock LED may be toggled by the hardware controller before the tap sees the event; no character leaks either way

## 10. Success Metrics

- Zero unintended keystrokes reaching apps while lock is active, across real meeting usage
- With auto-lock enabled: a cat landing or sitting on the keyboard triggers the lock within the first few keystrokes/seconds; zero false-positive locks during normal typing (including sustained 80–100+ WPM) over a week of use
- No crashes requiring a hard restart to regain keyboard control

## 11. Open Questions

- [ ] Should burst thresholds become user-configurable if real-cat QA shows they need per-cat tuning?
- [ ] Should an auto-lock event be visually distinguished from a manual lock (e.g. banner says "Auto-locked")?

## 12. Milestones

1. ~~**Prototype:** CGEventTap suppressing all keyboard input~~ ✅
2. ~~**Menu bar app:** status item with lock/unlock states~~ ✅
3. ~~**Unlock flow:** menu-click unlock (replaced typed code)~~ ✅
4. ~~**Polish:** transparent banner, launch-at-login, fn-key coverage, crash-safety~~ ✅
5. **Real-world test:** several actual Zoom meetings with the cat as QA — ongoing
6. **v1.1 auto-lock:** first pass (rate-only) failed real-cat + fast-typing QA; revised to concurrency/hold-duration detection — in re-test
