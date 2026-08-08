import AppKit
import ServiceManagement

/// Aloud — read the selection out loud, in a good voice, with no network.
///
/// Menu bar app. One hotkey grabs whatever is selected, hands it to Kokoro,
/// and shows a floating panel while it reads.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private var engine: SpeechEngine!
    private var hud: ReaderHUD!
    private let hotkey = HotkeyManager()
    private var statusItem: NSStatusItem!
    private var voiceMenuItems: [NSMenuItem] = []
    private var speedMenuItems: [NSMenuItem] = []

    /// Guards the capture window, where engine.speaking is still false —
    /// without it a quick double press launches two overlapping reads.
    private let readLock = NSLock()

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = SpeechEngine(voice: config.voice, speed: config.speed)
        hud = makeHUD()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◍"
        statusItem.menu = buildMenu()

        hotkey.onPressed = { [weak self] in self?.hotkeyPressed() }
        hotkey.register(combo: config.hotkey)

        // Load the model in the background so the first read is not a stall.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? self?.engine.load()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        hotkey.unregister()
    }

    private func makeHUD() -> ReaderHUD {
        ReaderHUD(
            engine: engine,
            speedLabel: speedLabel(config.speed),
            liquidGlass: config.liquidGlass,
            onStop: { [weak self] in self?.stopSpeaking() },
            onToggle: { [weak self] in self?.engine.togglePause() },
            onSeek: { [weak self] fraction in self?.engine.seek(fraction: fraction) },
            onSkip: { [weak self] seconds in self?.engine.seek(seconds: seconds) },
            onSpeed: { [weak self] in self?.cycleSpeed() ?? "1×" }
        )
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        handlers.removeAll()
        voiceMenuItems.removeAll()
        speedMenuItems.removeAll()

        let combo = HotkeyManager.pretty(config.hotkey)
        menu.addItem(
            makeItem("Read selection   \(combo)") { [weak self] in
                self?.readSelection()
            })
        menu.addItem(makeItem("Stop") { [weak self] in self?.stopSpeaking() })
        menu.addItem(.separator())

        let voiceMenu = NSMenu()
        for (label, id) in featuredVoices {
            let item = makeItem(label) { [weak self] in self?.pickVoice(id) }
            item.state = id == config.voice ? .on : .off
            item.representedObject = id
            voiceMenu.addItem(item)
            voiceMenuItems.append(item)
        }
        let voices = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        voices.submenu = voiceMenu
        menu.addItem(voices)

        let speedMenu = NSMenu()
        for value in speedPresets {
            let item = makeItem(speedLabel(value)) { [weak self] in
                self?.pickSpeed(value)
            }
            item.state = abs(value - config.speed) < 0.01 ? .on : .off
            item.representedObject = value
            speedMenu.addItem(item)
            speedMenuItems.append(item)
        }
        let speeds = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speeds.submenu = speedMenu
        menu.addItem(speeds)

        menu.addItem(.separator())
        menu.addItem(makeItem("Preview voice") { [weak self] in self?.preview() })

        let login = makeItem("Start at login") { [weak self] in self?.toggleLoginItem() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if #available(macOS 26.0, *) {
            let glass = makeItem("Liquid Glass HUD") { [weak self] in
                self?.toggleLiquidGlass()
            }
            glass.state = config.liquidGlass ? .on : .off
            menu.addItem(glass)
        }

        menu.addItem(
            makeItem("Grant Accessibility access…") { Self.openAccessibilitySettings() })
        menu.addItem(.separator())
        menu.addItem(
            makeItem("Quit Aloud") { [weak self] in
                self?.engine.stop()
                NSApp.terminate(nil)
            })
        return menu
    }

    private func makeItem(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = nil
        handlers[ObjectIdentifier(item)] = handler
        return item
    }

    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    @objc private func menuAction(_ sender: NSMenuItem) {
        handlers[ObjectIdentifier(sender)]?()
    }

    private func pickVoice(_ id: String) {
        for item in voiceMenuItems {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
        config.voice = id
        engine.voice = id
        config.save()
        preview()
    }

    private func pickSpeed(_ value: Double) {
        for item in speedMenuItems {
            item.state = abs(((item.representedObject as? Double) ?? 0) - value) < 0.01 ? .on : .off
        }
        config.speed = value
        engine.speed = value
        config.save()
        hud.setSpeedLabel(speedLabel(value))
    }

    /// HUD speed button: advance to the next preset, return its label.
    ///
    /// Kokoro applies speed at synthesis time, so a change takes effect from
    /// the next sentence synthesised, not the audio already buffered.
    private func cycleSpeed() -> String {
        let index = speedPresets.enumerated().min {
            abs($0.element - config.speed) < abs($1.element - config.speed)
        }?.offset ?? 2
        let value = speedPresets[(index + 1) % speedPresets.count]
        pickSpeed(value)
        return speedLabel(value)
    }

    private func toggleLiquidGlass() {
        config.liquidGlass.toggle()
        config.save()
        let placement = hud.placement
        hud.close()
        hud = makeHUD()
        statusItem.menu = buildMenu()
        hud.adopt(placement)

        if placement.visible, let name = placement.sourceName {
            // The panel was up (likely mid-read): keep it up, where it was,
            // showing what it was showing — just in the new chrome.
            hud.setSource(name: name, icon: placement.sourceIcon)
            hud.show()
        } else {
            // Otherwise flash a sample so the change is visible immediately.
            hud.setMessage(
                config.liquidGlass ? "Liquid glass" : "Classic",
                status: "HUD style updated")
            hud.show()
            hud.hide(after: 1.6)
        }
    }

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Login item change failed: \(error)")
        }
        statusItem.menu = buildMenu()
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Actions

    private func hotkeyPressed() {
        // Pressing the hotkey while it is talking means "stop".
        if engine.speaking {
            stopSpeaking()
            return
        }
        readSelection()
    }

    private func readSelection() {
        // Note where the text is coming from while that app is still
        // frontmost — the HUD shows its icon and name.
        let front = NSWorkspace.shared.frontmostApplication
        hud.setSource(name: front?.localizedName ?? "Selection", icon: front?.icon)

        let restore = config.restoreClipboard
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard self.readLock.try() else { return }
            defer { self.readLock.unlock() }

            // Let the hotkey modifiers lift before we synthesise Command-C.
            Thread.sleep(forTimeInterval: 0.12)

            let text: String
            do {
                text = try SelectionCapture.capture(restoreClipboard: restore)
            } catch {
                DispatchQueue.main.async {
                    self.hud.setMessage(
                        "Aloud needs Accessibility access",
                        status: "System Settings › Privacy & Security › Accessibility")
                    self.hud.show()
                    self.hud.hide(after: 4.0)
                    Self.openAccessibilitySettings()
                }
                return
            }

            DispatchQueue.main.async {
                if text.isEmpty {
                    self.hud.setMessage(
                        "Nothing selected", status: "Highlight some text and try again")
                    self.hud.show()
                    self.hud.hide(after: 1.8)
                } else {
                    self.speak(text)
                }
            }
        }
    }

    private func speak(_ text: String) {
        statusItem.button?.title = "◉"
        if !engine.ready {
            hud.setMessage("Warming up the voice…", status: "loading the model")
        }
        hud.show()

        engine.speak(
            text,
            onDone: { [weak self] in
                DispatchQueue.main.async {
                    self?.statusItem.button?.title = "◍"
                    self?.hud.hide(after: 0.7)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.statusItem.button?.title = "◍"
                    self?.hud.setMessage(
                        "Could not read that", status: String("\(error)".prefix(90)))
                    self?.hud.show()
                    self?.hud.hide(after: 4.0)
                }
            })
    }

    private func stopSpeaking() {
        engine.stop()
        statusItem.button?.title = "◍"
        hud.hide(after: 0)
    }

    private func preview() {
        hud.setSource(name: "Aloud", icon: NSApp.applicationIconImage)
        speak("This is how I sound. Highlight anything and press the hotkey.")
    }
}
