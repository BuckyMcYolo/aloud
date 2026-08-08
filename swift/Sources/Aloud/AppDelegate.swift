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
        statusItem.button?.image = Self.barsImage(Self.idleLevels)
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

        let shortcutMenu = NSMenu()
        for combo in hotkeyPresets {
            let item = makeItem(HotkeyManager.pretty(combo)) { [weak self] in
                self?.pickHotkey(combo)
            }
            item.state = combo == config.hotkey ? .on : .off
            shortcutMenu.addItem(item)
        }
        let shortcuts = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcuts.submenu = shortcutMenu
        menu.addItem(shortcuts)

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

    private func pickHotkey(_ combo: String) {
        config.hotkey = combo
        config.save()
        hotkey.register(combo: combo)
        // Rebuild so the checkmark and the "Read selection" title both update.
        statusItem.menu = buildMenu()
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

    // MARK: - Menu bar waveform

    /// The menu bar icon is a tiny waveform: still when idle, dancing while
    /// it reads. A template image, so it follows menu bar light/dark.
    private static let idleLevels: [CGFloat] = [0.45, 0.8, 1.0, 0.65, 0.35]
    private static let danceFrames: [[CGFloat]] = [
        [0.4, 0.9, 0.6, 1.0, 0.5],
        [0.7, 0.5, 1.0, 0.6, 0.9],
        [0.5, 1.0, 0.7, 0.8, 0.4],
        [0.9, 0.6, 0.9, 0.4, 0.7],
        [0.6, 0.8, 0.5, 1.0, 0.8],
        [1.0, 0.5, 0.8, 0.6, 0.5],
    ]
    private var danceTimer: Timer?
    private var danceIndex = 0

    private static func barsImage(_ levels: [CGFloat]) -> NSImage {
        let size = NSSize(width: 18, height: 14)
        let barWidth: CGFloat = 2.4
        let image = NSImage(size: size, flipped: false) { rect in
            let count = CGFloat(levels.count)
            let gap = (rect.width - barWidth * count) / (count - 1)
            for (i, level) in levels.enumerated() {
                let height = max(2.5, level * rect.height)
                let bar = NSRect(
                    x: CGFloat(i) * (barWidth + gap),
                    y: (rect.height - height) / 2,
                    width: barWidth, height: height)
                NSColor.black.set()
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
                    .fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setSpeakingIndicator(_ speaking: Bool) {
        if speaking {
            guard danceTimer == nil else { return }
            danceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.danceIndex = (self.danceIndex + 1) % Self.danceFrames.count
                    self.statusItem.button?.image =
                        Self.barsImage(Self.danceFrames[self.danceIndex])
                }
            }
        } else {
            danceTimer?.invalidate()
            danceTimer = nil
            statusItem.button?.image = Self.barsImage(Self.idleLevels)
        }
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
        setSpeakingIndicator(true)
        if !engine.ready {
            hud.setMessage("Warming up the voice…", status: "loading the model")
        }
        hud.show()

        engine.speak(
            text,
            onDone: { [weak self] in
                DispatchQueue.main.async {
                    self?.setSpeakingIndicator(false)
                    self?.hud.hide(after: 0.7)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.setSpeakingIndicator(false)
                    self?.hud.setMessage(
                        "Could not read that", status: String("\(error)".prefix(90)))
                    self?.hud.show()
                    self?.hud.hide(after: 4.0)
                }
            })
    }

    private func stopSpeaking() {
        engine.stop()
        setSpeakingIndicator(false)
        hud.hide(after: 0)
    }

    private func preview() {
        hud.setSource(name: "Aloud", icon: NSApp.applicationIconImage)
        speak("This is how I sound. Highlight anything and press the hotkey.")
    }
}
