# Keyboard Lock

A tiny macOS menu bar app that locks the keyboard system-wide — built so a
cat walking across the keyboard during a Zoom call can't mute you, trigger
shortcuts, or type into chat. Video/audio and the meeting itself are
untouched; only the keyboard is suppressed until you unlock from the menu
bar. The trackpad/mouse stay fully functional the whole time, so unlocking
is just a click.

Not a security tool — see PRD non-goals. Anyone with physical access can
still reboot the Mac to regain control.

## Build

```sh
./Scripts/build_app.sh
```

This compiles a release binary and packages it into `build/KeyboardLock.app`
(ad-hoc code-signed, so macOS TCC permission grants persist across rebuilds
as long as the bundle identifier doesn't change).

## First run: grant permissions

```sh
open build/KeyboardLock.app
```

On first launch macOS will prompt for **Accessibility**. You also need to
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
- **Launch at login**: menu bar icon → "Launch at Login" (off by default).

While locked, a banner appears near the top of the screen reading "Keyboard
Locked — Unlock in menu dropdown", and the menu bar icon switches to a
filled lock.

## Design note: why unlock is menu-only, not a typed code

The original PRD called for an unlock code typed while locked (FR3–FR5,
FR8), checked against a rolling keystroke buffer. In testing that path was
unreliable — locking worked, but the typed code wasn't reliably recognized,
requiring a force-quit to regain keyboard control. Rather than debug the
`CGEventTap` keycode-to-character translation further, the interaction was
simplified: the keyboard is fully suppressed while locked (no exceptions,
no code to remember or mistype), and unlocking happens with a mouse/trackpad
click on the menu bar item instead. This also sidesteps an internal
inconsistency in the original PRD, which asked for trackpad events to be
suppressed too (FR2) while also relying on mouse clicks for a forgot-the-code
fallback (Edge Cases) — those can't both hold under one `CGEventTap`, since
it can't distinguish a cat's paw from an intentional click.

If you forget to unlock or the menu becomes unreachable for some reason, the
same fallbacks as before still apply: a hard reset (FR10) always works, and
if the app crashes the OS tears down the event tap with the process, so
normal keyboard input returns automatically with no watchdog needed.

## Known limitations / v1 scope (per PRD non-goals)

- Zoom-specific shortcuts (mute/camera) aren't available while locked — use
  Zoom's on-screen controls with the mouse, or unlock first.
- No idle auto-lock; you must trigger the lock yourself.
- macOS only, single user, no cloud config.
