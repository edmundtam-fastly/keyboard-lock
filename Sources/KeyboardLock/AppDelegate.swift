import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayWindow?
    private let controller = LockController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        controller.onStateChange = { [weak self] locked in
            DispatchQueue.main.async { self?.stateChanged(locked: locked) }
        }

        _ = Permissions.isAccessibilityTrusted(prompt: true)

        if !controller.start() {
            showPermissionAlert()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(locked: false)
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggleItem = NSMenuItem(title: "Lock Keyboard (^⌥⌘L)", action: #selector(toggleLock), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.tag = 100
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = ConfigStore.load().launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Keyboard Lock", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func toggleLock() {
        if controller.isLocked {
            controller.unlock()
            return
        }
        guard requireTrusted() else { return }
        // The tap may have failed to start at launch (e.g. permissions were
        // granted after this process started). Retry here — a no-op if it's
        // already running — so lock() never reports "locked" without a live
        // tap actually suppressing input.
        guard controller.start() else {
            showPermissionAlert()
            return
        }
        controller.lock()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        var config = ConfigStore.load()
        config.launchAtLogin.toggle()
        ConfigStore.save(config)
        sender.state = config.launchAtLogin ? .on : .off
        LaunchAtLogin.setEnabled(config.launchAtLogin)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func stateChanged(locked: Bool) {
        updateIcon(locked: locked)
        statusItem.menu?.items.first(where: { $0.tag == 100 })?.title =
            locked ? "Unlock Keyboard" : "Lock Keyboard (^⌥⌘L)"

        if locked {
            let overlay = OverlayWindow()
            overlay.show()
            self.overlay = overlay
        } else {
            overlay?.close()
            overlay = nil
        }
    }

    private func updateIcon(locked: Bool) {
        let symbolName = locked ? "lock.fill" : "lock.open"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: locked ? "Keyboard locked" : "Keyboard unlocked")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func requireTrusted() -> Bool {
        guard Permissions.isAccessibilityTrusted(prompt: false) else {
            showPermissionAlert()
            return false
        }
        return true
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permissions Required"
        alert.informativeText = "Keyboard Lock needs Accessibility and Input Monitoring permission to intercept keyboard input. Grant both in System Settings, then relaunch the app."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Open Input Monitoring Settings")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: Permissions.openAccessibilitySettings()
        case .alertSecondButtonReturn: Permissions.openInputMonitoringSettings()
        default: break
        }
    }
}
