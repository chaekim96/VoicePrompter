import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var overlay: OverlayController!
    private var windows: WindowManager!
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        model = AppModel()
        windows = WindowManager(model: model)
        overlay = OverlayController(model: model)
        overlay.actions = OverlayActions(openMainWindow: { [weak self] in self?.windows.show() })
        model.onRecenterRequest = { [weak self] in self?.overlay.recenter() }
        overlay.panel.orderFrontRegardless()

        // Dock icon on/off follows the setting, live.
        model.$settings.map(\.showInDock).removeDuplicates().sink { show in
            NSApp.setActivationPolicy(show ? .regular : .accessory)
        }.store(in: &cancellables)

        registerHotkeys()
        setUpStatusItem()
        let isTestRun = model.launch.autostart || model.launch.snapshot != nil || model.launch.audioFile != nil
        if model.settings.showWindowOnLaunch && !isTestRun { windows.show() }
        if model.launch.autostart { model.startTracking() }
        if let t = model.launch.quitAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
        if let url = model.launch.snapshot {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.overlay.writeSnapshot(to: url) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.stopTracking(reason: "quit") }

    /// Clicking the Dock icon (or opening the app again from Finder/Spotlight) brings up the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let hk = HotkeyManager.shared
        hk.register(Keys.space, Keys.ctrlOpt, display: "⌃⌥Space") { [weak self] in self?.model.toggleTracking(source: "hotkey") }
        hk.register(Keys.o, Keys.ctrlOpt, display: "⌃⌥O") { [weak self] in self?.windows.show() }
        hk.register(Keys.c, Keys.ctrlOpt, display: "⌃⌥C") { [weak self] in self?.model.clickThrough.toggle() }
        hk.register(Keys.r, Keys.ctrlOpt, display: "⌃⌥R") { [weak self] in self?.model.resetToStart() }
        hk.register(Keys.up, Keys.ctrlOpt, display: "⌃⌥↑") { [weak self] in self?.overlay.nudge(lines: -1) }
        hk.register(Keys.down, Keys.ctrlOpt, display: "⌃⌥↓") { [weak self] in self?.overlay.nudge(lines: 1) }
        hk.register(Keys.h, Keys.ctrlOpt, display: "⌃⌥H") { [weak self] in self?.model.overlayVisible.toggle() }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        model.$tracking.combineLatest(model.$isLost).sink { [weak self] state, lost in
            let symbol: String
            switch state {
            case .listening: symbol = lost ? "text.page.badge.magnifyingglass" : "waveform"
            case .starting: symbol = "ellipsis"
            case .error: symbol = "exclamationmark.triangle"
            case .stopped: symbol = "text.alignleft"
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoicePrompter")
                ?? NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "VoicePrompter")
            image?.isTemplate = true
            self?.statusItem.button?.image = image
        }.store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = model!
        func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.control, .option],
                  on: Bool = false, _ action: @escaping () -> Void) {
            let i = ClosureMenuItem(title: title, key: key, action: action)
            i.keyEquivalentModifierMask = mods
            i.state = on ? .on : .off
            menu.addItem(i)
        }
        item("Open VoicePrompter…", "o") { [weak self] in self?.windows.show() }
        menu.addItem(.separator())
        item(m.tracking.isActive ? "Pause Tracking" : "Start Tracking", " ") { m.toggleTracking(source: "menu") }
        item("Back to Start", "r") { m.resetToStart() }
        item("Click-Through", "c", on: m.clickThrough) { m.clickThrough.toggle() }
        item(m.overlayVisible ? "Hide Overlay" : "Show Overlay", "h") { m.overlayVisible.toggle() }
        menu.addItem(.separator())
        item("Edit Script…", "", []) { [weak self] in self?.windows.show(.script) }
        item("Import Script…", "", []) { [weak self] in self?.windows.importScript() }
        item("Settings…", ",", [.command]) { [weak self] in self?.windows.show(.appearance) }
        menu.addItem(.separator())
        item("Hide from Screen Capture", "", [], on: m.settings.protectFromCapture) { m.settings.protectFromCapture.toggle() }
        menu.addItem(.separator())
        item("Quit VoicePrompter", "q", [.command]) { NSApp.terminate(nil) }
    }

    /// App menu bar (shown when the Dock icon is on). Even without it, the Edit menu keeps ⌘C/⌘V/⌘A working.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { [weak self] in self?.windows.show(.appearance) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit VoicePrompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let win = NSMenu(title: "Window"); windowItem.submenu = win
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return main
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, key: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

setvbuf(stdout, nil, _IOLBF, 0)
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
