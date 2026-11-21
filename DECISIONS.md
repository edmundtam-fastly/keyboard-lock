# Engineering Decisions & Context

Why this app is built the way it is, and what you need to pick it up on a
different machine. [PRD.md](PRD.md) holds the product requirements and
revision history; [README.md](README.md) covers install and usage. This file
is the reasoning behind the code — the things that aren't recoverable by
reading it.

---

## 1. Picking the project up on a new machine

```sh
git clone https://github.com/edmundtam-fastly/keyboard-lock.git
cd keyboard-lock
./Scripts/setup_signing_identity.sh   # once per machine — see §3.2
./Scripts/build_app.sh                # → build/KeyboardLock.app
swift test                            # 27 tests, all should pass
```

Then copy the app to `/Applications`, clear Gatekeeper, and grant
permissions (README has the steps). Requires Xcode Command Line Tools for
the Swift toolchain; nothing else.

**Tooling notes carried over from the original setup:**

- Homebrew was not installed. The GitHub CLI was fetched directly from
  GitHub Releases into `~/bin`, with `export PATH="$HOME/bin:$PATH"` added
  to `~/.zshrc`. Redo that, or use Homebrew, as you prefer.
- `gh auth login` (web flow), then `gh auth setup-git` — the second step is
  easy to miss, and without it a plain `git push` fails with
  "could not read Username" even though `gh` itself is authenticated.
- **A Fastly policy hook blocks Claude Code from pushing to this repo**
  (personal GitHub account isn't an approved org destination) and caps
  shell commands at 600 bytes. Claude commits; you run `git push` and
  `gh release create` yourself. Not a bug — expect it.

---

## 2. Product-shape decisions

### 2.1 Unlock is a menu click, not a typed code

The original PRD specified a 4–10 character unlock code typed while locked,
matched against a rolling keystroke buffer. **Built, then removed.** In real
use the match was unreliable — locking worked, the code often wasn't
recognized, and recovery meant force-quitting the app. Rather than debug
keycode-to-character translation inside an event tap, the interaction was
simplified: nothing to remember, nothing to mistype, and unlocking is a
mouse click on the menu bar item.

This is only possible because of §2.2.

### 2.2 The trackpad is never suppressed

The original PRD asked for trackpad events to be intercepted *and* offered
"force-quit via Activity Monitor with the mouse" as the forgot-your-code
fallback. Those contradict: a session-level `CGEventTap` cannot distinguish
a cat's paw from a deliberate click, so suppressing pointer input also
removes the escape hatch.

Resolution: **pointer input is never part of the tap's event mask.** The
keyboard is fully suppressed; the mouse always works. That makes the menu
click a reliable unlock path and means a stuck lock is never possible while
the mouse is alive.

### 2.3 Auto-lock is opt-in and off by default

The original PRD explicitly declined always-on auto-locking. Burst detection
is heuristic and false positives interrupt real work, so it stays a menu
toggle the user arms deliberately.

### 2.4 Not a security tool

Stated in the PRD non-goals and worth repeating: this stops a cat, not a
person. A reboot always clears it, and that's an accepted fallback, not a
gap to close.

---

## 3. Build & distribution decisions

### 3.1 Swift Package Manager, not an Xcode project

An `.app` bundle is assembled by `Scripts/build_app.sh` (Info.plist with
`LSUIElement` for no Dock icon, then code signing). Keeps the repo
diff-friendly and buildable from a terminal with no project file to merge.

### 3.2 A persistent local signing certificate, not ad-hoc

**This one cost real debugging time, so don't undo it.** Ad-hoc signing
(`codesign --sign -`) computes the signature over the binary's contents, so
*every rebuild produces a different identity* and macOS silently invalidates
the prior Accessibility/Input Monitoring grants — while System Settings
still displays the old entry as enabled. The symptom is maddening: the
toggle says "on", the app insists permission is missing.

`Scripts/setup_signing_identity.sh` creates a self-signed code-signing
certificate ("KeyboardLock Local Dev") in the login keychain and trusts it
for code signing. TCC then keys off the stable certificate rather than the
binary hash, so grants survive rebuilds.

Per machine: run the script once. If Migration Assistant brings your login
keychain across, the identity comes with it and nothing is needed.

If grants ever do get into a bad state:
```sh
tccutil reset Accessibility com.edmundtam.keyboardlock
tccutil reset ListenEvent com.edmundtam.keyboardlock
```

### 3.3 Not notarized

No paid Apple Developer account, so downloaded copies hit Gatekeeper and
need the one-time "Open Anyway" flow (or `xattr -dr com.apple.quarantine`).
This recurs on **every new download** because each zip carries a fresh
quarantine flag — permissions, by contrast, are granted once per machine.
Documented in the README and in every release's notes, because it's the
single most common support question from coworkers.

### 3.4 Launch at login uses a LaunchAgent

A plain `~/Library/LaunchAgents` plist rather than `SMAppService`, so it
works regardless of where the `.app` lives. Uses `launchctl bootstrap` /
`bootout` (the modern subcommands; `load`/`unload` are deprecated).

**Gotcha that bit once:** the plist records whatever executable path was
current when the setting was enabled. It was pointing at the dev build
folder, so every login started that copy instead of `/Applications` — same
version at the time, but guaranteed to drift. If you move the app, toggle
launch-at-login off and on to rewrite the path.

---

## 4. Detection design

The auto-lock detector is the part that has changed most, driven entirely by
real-world failures. The full evolution matters because the naive version is
the one you'd naturally write again.

### 4.1 Rate-based detection failed in both directions

v1 fired on ≥6 keyDowns in 0.4s across ≥4 distinct keys — roughly "typing
too fast to be human." Two failures in testing:

- **False positives at 80–100 WPM.** Ordinary fast typing cleared it.
- **It missed an actual cat.** The cat's landing wasn't a rapid *sequence*;
  it was a few keys pressed *simultaneously and held*. The detector had
  explicitly filtered out held-key signal as autorepeat noise.

**Lesson: a cat's signature is concurrency and duration, not speed.**

### 4.2 Three independent triggers

Thresholds live in `Sources/KeyboardLock/LockLogic.swift`:

| Rule | Condition | Rationale |
|---|---|---|
| Paw landing | ≥4 non-modifier keys held at once | A body/paw covers several keys; rollover typing peaks around 2–3 |
| Cat sitting | ≥3 keys pinned ≥1.5s, **or** exactly 2 pinned that arrived within 120ms | See §4.3 |
| Violent mash | ≥8 keyDowns in 0.3s across ≥5 distinct keys | ~320 WPM instantaneous, far above the ~100 WPM that broke v1 |

Modifier keys never count — they arrive as `flagsChanged`, not
keyDown/keyUp, so holding Shift can't contribute. Autorepeat doesn't count
as a new press but does serve as a clock tick for the duration checks.

### 4.3 Co-arrival is what separates a paw from a hand

"Two keys held for 1.5s" is **not** inherently feline — holding W+A to
strafe in a game is exactly that, deliberately, for minutes. The real
discriminator is *when the keys arrived*: a paw is one physical event, so
its keys depress within milliseconds, while a human adds the second key as a
separate decision hundreds of milliseconds later.

Hence the tiering: 3+ pinned keys trigger regardless of timing (no common
human analogue), but exactly 2 require co-arrival within 120ms.

This idea is probably also the right fix if paw-landing ever false-triggers
— require co-arrival there too, rather than raising the key count.

### 4.4 Held-key counts are confirmed against hardware

Two of three rules rest on "this many keys are down right now," assembled
from keyDown/keyUp pairs. The tap can miss a keyUp (secure input fields, app
switches), leaving a phantom held key that inflates the count — three real
keys plus one ghost satisfies paw-landing during ordinary typing.

Before any trigger is acted on, held keys are re-probed via
`CGEventSource.keyState` and the rules re-evaluated; discarded triggers are
logged with how many entries were stale. Phantoms also age out after 10s.

### 4.5 Diagnostics instead of guesswork

Every auto-lock logs **which rule fired and with what counts** (never key
identities) to the unified log:

```sh
/usr/bin/log show --last 1h --predicate 'eventMessage contains "KeyboardLock"' --style compact
```

Caveat learned the hard way: these entries age out within about a day, so
they only help if checked promptly. That's what motivated §4.6.

### 4.6 Calibration records features, never keystrokes

For tuning, the app can record what the rules actually measure — keys held
at once, hold durations, arrival spread, keydowns and *distinct-key counts*
per window, plus which rule would have fired.

**It deliberately is not a keystroke recorder.** The rules never consider
key identity, so none is written to disk: the log cannot reconstruct typed
text by construction rather than by redaction. Analyze with
`./Scripts/analyze_calibration.py`, which reports how close real typing came
to each threshold and what to change.

---

## 5. Suppression correctness: the stuck-key class of bugs

Two bugs, same root cause, worth understanding together because any future
change to the suppression logic can reintroduce them.

**The shape:** a key's *press* reaches apps before the lock engages (with
auto-lock, the first keystrokes necessarily precede detection — evidence has
to accumulate), then the lock swallows its *release*. The app is left
believing the key is still held.

- **Regular keys** → stuck autorepeat, the macOS accent-picker popup, input
  feeling "off" after unlocking.
- **Modifier keys** → much worse. A stuck Globe/Fn turns every "e" into the
  emoji picker; stuck ⌘ turns letters into menu shortcuts. This also meant
  the lock hotkey could poison itself: `⌃⌥⌘L` engages the lock, then its own
  three modifier releases get swallowed.

**The fix, applied to both:** at lock time, snapshot what is physically down
— `heldKeys` for regular keys, `CGEventSource.flagsState` for modifiers.
While locked, let through *only* the releases of those snapshotted items,
exactly once each. A bare release types nothing, so the lock isn't weakened.
A modifier event that *presses* anything new stays suppressed — a Globe
press is itself the emoji trigger.

Caps Lock is excluded: it's a toggle, not a hold, so there's no release to
drain. Worst case the light stays on; tap it to clear.

---

## 6. Accepted limitations

Deliberate non-fixes. Reopen only with new information.

- **Secure input fields block everything.** While a password field has
  focus, macOS hides keyboard events from all event taps — auto-lock can't
  fire and `⌃⌥⌘L` won't register. The menu item still works. Unfixable
  from user space.
- **System-reserved shortcuts can't be suppressed** (⌘Tab, Spotlight,
  Mission Control). macOS intercepts them above any third-party tap. No app
  can block these.
- **Holding 3+ non-modifier keys for 1.5s+ triggers auto-lock** even when
  deliberate (some flight sims, accessibility setups). Toggle auto-lock off
  for those sessions. Considered and rejected: frontmost-app detection to
  exempt games — classifying "a game" is unbounded complexity for a problem
  a menu toggle already solves.
- **The first keystrokes of a cat event always reach apps.** Detection
  requires evidence; it cannot precede it.
- **arm64 only.** Builds native; add `--arch arm64 --arch x86_64` if an
  Intel Mac ever needs it.

---

## 7. Testing approach

Detection and drain rules live in `LockLogic.swift` as **pure functions with
no CGEventTap, AppKit, or singleton state**, specifically so they're
unit-testable — the event tap itself can't be exercised in CI, and physical
keystrokes can't be simulated meaningfully.

`Tests/KeyboardLockTests/` holds 27 tests in three groups: the modifier
release state machine (each test named for the real symptom it prevents),
the three trigger rules at their boundaries, and replayed input traces
(110 WPM rollover typing, bursty word clusters, a gaming session, a paw
landing, a cat sitting). Before changing any threshold, run `swift test` —
the traces are the regression net for exactly the failures that have already
happened once.

What tests can't cover, and must be checked by hand: permission grants,
actual suppression, and anything involving a real cat.

---

## 8. Open / unvalidated

As of v1.3.0:

- **Hardware-confirmation fix (§4.4) is unvalidated against the false
  positives it was written for.** Turn on auto-lock and use normally.
- **Stuck-modifier fix (§5) has not had a real-cat test.** After a cat
  event, confirm "e" types an "e".
- **Coworkers are on v1.2.0** — the public release is behind. Cut v1.3.0
  once the above hold up:
  ```sh
  git tag -a v1.3.0 -m "..." && git push origin v1.3.0
  gh release create v1.3.0 build/KeyboardLock.zip --title "..." --notes-file build/release-notes-v1.3.0.md
  ```
  Release notes should always carry the Gatekeeper steps (§3.3) and split
  "new install" from "upgrade" — first-timers need the permission grant,
  upgraders don't.
