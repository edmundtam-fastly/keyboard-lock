# Keyboard Lock

A tiny macOS menu bar app that locks the keyboard system-wide — built so a
cat walking across the keyboard during a Zoom call can't mute you, trigger
shortcuts, or type into chat. Video/audio and the meeting itself are
untouched; only the keyboard is suppressed until you unlock from the menu
bar. The trackpad/mouse stay fully functional the whole time, so unlocking
is just a click.

Not a security tool — see [PRD.md](PRD.md) non-goals. Anyone with physical
access can still reboot the Mac to regain control.

## Install from a GitHub release (most users)

Grab `KeyboardLock.zip` from the latest
[release](https://github.com/edmundtam-fastly/keyboard-lock/releases),
unzip it, and move `KeyboardLock.app` to `/Applications`.

### Getting past Gatekeeper (first launch only)

Because the app isn't notarized by Apple, macOS blocks the first launch of
a downloaded copy. This is a one-time step per download — easy to forget by
the time you install an update, so it's spelled out here:

1. Double-click the app once — it gets blocked and shows a dialog. Close it.
2. Go to **System Settings → Privacy & Security**, scroll down — there's a
   line like *"KeyboardLock" was blocked to protect your Mac* with an
   **Open Anyway** button. Click it and authenticate.
3. Double-click the app again — a second confirmation dialog appears,
   click **Open**.

Alternatively, skip all three steps with one Terminal command, which
removes the downloaded-from-the-internet quarantine flag directly:

```sh
xattr -dr com.apple.quarantine /Applications/KeyboardLock.app
```

Then continue with "First run: grant permissions" below.

## Build from source

```sh
./Scripts/build_app.sh
```

This compiles a release binary and packages it into `build/KeyboardLock.app`
(locally code-signed, so macOS TCC permission grants persist across rebuilds
as long as the bundle identifier doesn't change). Locally built copies have
no quarantine flag, so the Gatekeeper section above doesn't apply.

## First run: grant permissions

Launch the app (from `/Applications`, or `open build/KeyboardLock.app` if
you built from source). On first launch macOS will prompt for **Accessibility**. You also need to
grant **Input Monitoring** manually — the app's menu offers a shortcut to
both panes (via the "Permissions Required" alert if the tap fails to start,
or open them directly):

- System Settings → Privacy & Security → Accessibility → enable "KeyboardLock"
- System Settings → Privacy & Security → Input Monitoring → enable "KeyboardLock"

After granting, quit and relaunch the app once.

## Usage

- **Lock**: click the menu bar lock icon → "Lock Keyboard", or press
  `Control+Option+Command+L` anywhere.
- **Unlock**: click the menu bar lock icon → "Unlock Keyboard". The trackpad
  and mouse are never blocked, so this always works even while the keyboard
  is fully locked.
- **Auto-Lock on Key Burst** (off by default): menu bar icon →
  "Auto-Lock on Key Burst". When enabled, input that looks like a cat locks
  the keyboard automatically, for the times the cat gets there before you
  do. Three signatures trigger it, any one alone:
  - **Paw landing** — 4+ keys physically held down at the same moment
  - **Cat sitting** — 3+ keys held together for 1.5s or more, or exactly 2
    keys that landed within 120ms of each other and stayed down. (The
    co-arrival requirement is what separates a paw — one physical event
    hitting both keys at once — from you deliberately holding two keys,
    like W+A to strafe in a game.)
  - **Violent mash** — 8+ keystrokes within 0.3s across 5+ distinct keys
    (~320 WPM; normal fast typing tops out far below this)

  A single held key (backspace, arrows) never triggers it, and modifier
  keys (Shift/Ctrl/Option/Cmd) never count toward held-key totals. The
  first few keystrokes of a cat event necessarily reach apps before a
  threshold trips; detection can't precede evidence.
- **Launch at login**: menu bar icon → "Launch at Login" (off by default).

While locked, a banner appears near the top of the screen reading "Keyboard
Locked — Unlock in menu dropdown", and the menu bar icon switches to a
filled lock.

If auto-lock ever false-triggers during normal typing (or misses your cat),
every auto-lock logs which rule fired (rule name and counts only, never key
identities) — check it with:

```sh
/usr/bin/log show --last 1h --predicate 'eventMessage contains "KeyboardLock: auto-lock fired"'
```

The thresholds live in `Sources/KeyboardLock/LockLogic.swift`
(`concurrentHeldThreshold`, the `sustained*` constants, and the `burst*`
constants) — tune, rebuild, and run `swift test` to check the change against
the simulated typing/gaming/cat traces.

## Design note: why unlock is menu-only, not a typed code

The original draft of the PRD called for an unlock code typed while locked,
checked against a rolling keystroke buffer. In testing that path was
unreliable — locking worked, but the typed code wasn't reliably recognized,
requiring a force-quit to regain keyboard control. Rather than debug the
`CGEventTap` keycode-to-character translation further, the interaction was
simplified: the keyboard is fully suppressed while locked (no exceptions,
no code to remember or mistype), and unlocking happens with a mouse/trackpad
click on the menu bar item instead. This also sidesteps an internal
inconsistency in that draft, which asked for trackpad events to be
suppressed too while also relying on mouse clicks for a forgot-the-code
fallback — those can't both hold under one `CGEventTap`, since it can't
distinguish a cat's paw from an intentional click.

If you forget to unlock or the menu becomes unreachable for some reason, the
same fallbacks still apply: a hard reset always works, and if the app
crashes the OS tears down the event tap with the process, so normal keyboard
input returns automatically with no watchdog needed.

See [PRD.md](PRD.md) for the full requirement list and revision history.

## Known limitations

- **Password fields block everything.** While a secure input field has focus
  (login prompts, password managers), macOS hides keyboard events from all
  event taps — so auto-lock can't fire and `⌃⌥⌘L` won't register. The menu
  bar item still works, since the mouse is never intercepted.
- **Deliberate key-holding can still look feline.** Holding three or more
  non-modifier keys for 1.5s+ triggers the cat-sitting rule even when it's
  you doing it (some flight sims, accessibility setups). Two-key holds like
  W+A strafing are explicitly handled — they only trigger if both keys land
  within 120ms of each other, which deliberate presses don't. If a workflow
  of yours does trip it, turn auto-lock off from the menu while you're in it.
- **System-reserved shortcuts can't be blocked.** ⌘Tab, Spotlight, Mission
  Control and friends are intercepted by macOS above any third-party event
  tap. No app, including this one, can suppress them.
- **Caps Lock is a toggle, not a hold** — it's excluded from modifier
  tracking, so a cat toggling it may leave the light on. Tap it to clear.
- Zoom-specific shortcuts (mute/camera) aren't available while locked — use
  Zoom's on-screen controls with the mouse, or unlock first.
- macOS only, single user, no cloud config.
