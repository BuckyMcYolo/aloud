import AppKit

/// The floating reader panel.
///
/// Design notes, so future edits stay coherent:
///
/// The panel is a rounded card that sits low on the screen, out of the way of
/// what you were reading. Top row: the icon and name of the app being read
/// from. Middle: the waveform — it is not decoration, it is the RMS envelope
/// of the synthesised audio with a playhead sweeping left to right, and it is
/// also the scrubber: click or drag anywhere on it to jump. Bottom: transport
/// controls. Everything but the waveform is deliberately quiet.
///
///   ink      #12121A   scrim over the vibrancy layer
///   paper    #EDEAE3   app name, control glyphs
///   muted    #8A8794   time readout, hints, secondary state
///   signal   #9A8CF0   playhead, lit waveform bars, hover rings
///   shadow   #443C6B   unplayed waveform bars
enum Palette {
    static let ink = rgb(0x12121A, alpha: 0.72)
    static let paper = rgb(0xEDEAE3)
    static let muted = rgb(0x8A8794)
    static let signal = rgb(0x9A8CF0)
    static let shadow = rgb(0x443C6B)

    private static func rgb(_ hex: Int, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

private let panelWidth: CGFloat = 400
private let panelHeight: CGFloat = 172
private let bottomInset: CGFloat = 140
private let cornerRadius: CGFloat = 24
private let waveBuckets = 46
private let skipSeconds = 10.0

private func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    if let descriptor = base.fontDescriptor.withDesign(.rounded),
        let rounded = NSFont(descriptor: descriptor, size: size)
    {
        return rounded
    }
    return base
}

private func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
    guard
        let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                .init(pointSize: pointSize, weight: .medium))
    else { return nil }
    let out = NSImage(size: base.size)
    out.lockFocus()
    let rect = NSRect(origin: .zero, size: base.size)
    base.draw(in: rect)
    color.set()
    rect.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

private func formatTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return "\(total / 60):" + String(format: "%02d", total % 60)
}

// MARK: - Waveform

/// The signature element: the audio you are hearing — and the scrubber.
final class WaveView: NSView {
    var envelope: [Double] = Array(repeating: 0.08, count: waveBuckets) {
        didSet {
            idle = false
            needsDisplay = true
        }
    }
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    var idle = true {
        didSet { needsDisplay = true }
    }
    var onSeek: ((Double) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { seek(with: event) }
    override func mouseDragged(with event: NSEvent) { seek(with: event) }

    private func seek(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0 else { return }
        let fraction = min(1.0, max(0.0, point.x / bounds.width))
        onSeek?(fraction)
        progress = fraction
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = envelope.count
        guard count > 0 else { return }

        let slot = bounds.width / CGFloat(count)
        let barWidth = max(1.5, slot - 1.6)
        let mid = bounds.height / 2
        let playhead = progress * Double(count)

        for (i, level) in envelope.enumerated() {
            // A floor keeps silence legible as a thin seam rather than a gap.
            let height = max(2.0, CGFloat(level) * bounds.height)
            let bar = NSRect(
                x: CGFloat(i) * slot, y: mid - height / 2,
                width: barWidth, height: height)

            if idle {
                Palette.muted.withAlphaComponent(0.25).set()
            } else if Double(i) < playhead - 1 {
                Palette.signal.withAlphaComponent(0.95).set()
            } else if Double(i) < playhead {
                // Soften the leading edge so the sweep does not stutter.
                Palette.signal.withAlphaComponent(0.55).set()
            } else {
                Palette.shadow.withAlphaComponent(0.85).set()
            }

            NSBezierPath(
                roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2
            ).fill()
        }
    }
}

// MARK: - Buttons

/// A transport control: an SF Symbol with a hover ring, nothing more.
class GlyphButton: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }
    var action: (() -> Void)?
    fileprivate var hovering = false {
        didSet { needsDisplay = true }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { action?() }

    fileprivate func drawHoverRing() {
        guard hovering else { return }
        let ring: CGFloat = 17
        let circle = NSRect(
            x: bounds.midX - ring, y: bounds.midY - ring,
            width: ring * 2, height: ring * 2)
        Palette.signal.withAlphaComponent(0.18).set()
        NSBezierPath(ovalIn: circle).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHoverRing()
        guard let image else { return }
        let target = NSRect(
            x: bounds.midX - image.size.width / 2,
            y: bounds.midY - image.size.height / 2,
            width: image.size.width, height: image.size.height)
        image.draw(in: target)
    }
}

/// Same interaction as GlyphButton, but a short text glyph — the 1× speed.
final class TextButton: GlyphButton {
    var title = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHoverRing()
        guard !title.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: roundedFont(size: 14, weight: .semibold),
            .foregroundColor: Palette.paper,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

// MARK: - Panel

/// Owns the panel and keeps it in step with playback.
@MainActor
final class ReaderHUD {
    private let engine: SpeechEngine
    private let onStop: () -> Void
    private let onToggle: () -> Void
    private let onSkip: (Double) -> Void
    private let onSpeed: () -> String

    private var panel: NSPanel!
    private var iconView: NSImageView!
    private var nameLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var wave: WaveView!
    private var speedButton: TextButton!
    private var playButton: GlyphButton!

    private var playImage: NSImage?
    private var pauseImage: NSImage?
    private var showingPause = true

    private var timer: Timer?
    private var hideAt: Date?
    private var sessionID: Int?
    private var envelopeVersion = -1
    private var messageMode = false
    private var sourceName: String?
    private var sourceIcon: NSImage?
    private var userMoved = false
    private var programmaticMove = false
    private var moveObserver: NSObjectProtocol?

    init(
        engine: SpeechEngine,
        speedLabel: String,
        liquidGlass: Bool = false,
        onStop: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onSeek: @escaping (Double) -> Void,
        onSkip: @escaping (Double) -> Void,
        onSpeed: @escaping () -> String
    ) {
        self.engine = engine
        self.onStop = onStop
        self.onToggle = onToggle
        self.onSkip = onSkip
        self.onSpeed = onSpeed
        build(speedLabel: speedLabel, liquidGlass: liquidGlass, onSeek: onSeek)
    }

    /// Tear down the panel; used when the HUD is rebuilt with a new style.
    func close() {
        timer?.invalidate()
        timer = nil
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        panel.orderOut(nil)
    }

    /// Everything a rebuilt HUD needs to appear exactly where this one was.
    struct Placement {
        let origin: NSPoint
        let userMoved: Bool
        let visible: Bool
        let sourceName: String?
        let sourceIcon: NSImage?
    }

    var placement: Placement {
        Placement(
            origin: panel.frame.origin,
            userMoved: userMoved,
            visible: panel.alphaValue > 0.5 && panel.isVisible,
            sourceName: sourceName,
            sourceIcon: sourceIcon)
    }

    func adopt(_ placement: Placement) {
        programmaticMove = true
        panel.setFrameOrigin(placement.origin)
        programmaticMove = false
        userMoved = placement.userMoved
        if let name = placement.sourceName {
            sourceName = name
            sourceIcon = placement.sourceIcon
        }
    }

    private func build(
        speedLabel: String, liquidGlass: Bool, onSeek: @escaping (Double) -> Void
    ) {
        let screen = NSScreen.main?.frame ?? .zero
        let frame = NSRect(
            x: (screen.width - panelWidth) / 2, y: bottomInset,
            width: panelWidth, height: panelHeight)

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary,
        ]
        panel.alphaValue = 0

        // A position the user chose by dragging is theirs; remember that and
        // stop re-centering on show.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.programmaticMove else { return }
                self.userMoved = true
            }
        }

        let bounds = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        // The chrome: Liquid Glass on macOS 26+, otherwise the classic
        // vibrancy blur under an ink scrim. Same content either way.
        let blur: NSView
        if liquidGlass, #available(macOS 26.0, *) {
            let content = NSView(frame: bounds)
            content.autoresizingMask = [.width, .height]
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = cornerRadius
            // Clear, untinted glass — the whole point of the mode is seeing
            // the desktop refract through the panel. Text gets a soft shadow
            // instead of a scrim for legibility.
            glass.style = .clear
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            panel.contentView = glass
            blur = content
        } else {
            let vibrancy = NSVisualEffectView(frame: bounds)
            vibrancy.material = .hudWindow
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            vibrancy.wantsLayer = true
            vibrancy.layer?.cornerRadius = cornerRadius
            vibrancy.layer?.masksToBounds = true
            vibrancy.autoresizingMask = [.width, .height]
            panel.contentView = vibrancy

            let scrim = NSView(frame: bounds)
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = Palette.ink.cgColor
            scrim.layer?.cornerRadius = cornerRadius
            scrim.autoresizingMask = [.width, .height]
            vibrancy.addSubview(scrim)
            blur = vibrancy
        }

        // Source row: the app being read from.
        iconView = NSImageView(frame: NSRect(x: 0, y: 131, width: 26, height: 26))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6
        iconView.layer?.masksToBounds = true
        iconView.isHidden = true
        blur.addSubview(iconView)

        nameLabel = makeLabel(
            font: roundedFont(size: 18, weight: .semibold), color: Palette.paper)
        nameLabel.frame = NSRect(x: 20, y: 131, width: panelWidth - 40, height: 24)
        blur.addSubview(nameLabel)

        if liquidGlass {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 3
            nameLabel.shadow = textShadow
        }

        // Waveform scrubber.
        wave = WaveView(
            frame: NSRect(x: 28, y: 92, width: panelWidth - 56, height: 32))
        wave.onSeek = onSeek
        blur.addSubview(wave)

        timeLabel = makeLabel(
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            color: Palette.muted)
        timeLabel.frame = NSRect(x: 20, y: 72, width: panelWidth - 40, height: 14)
        timeLabel.alignment = .center
        blur.addSubview(timeLabel)

        if liquidGlass {
            let textShadow = NSShadow()
            textShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            textShadow.shadowBlurRadius = 3
            timeLabel.shadow = textShadow
        }

        // Transport row.
        playImage = symbol("play.fill", pointSize: 17, color: Palette.paper)
        pauseImage = symbol("pause.fill", pointSize: 17, color: Palette.paper)

        func place<T: GlyphButton>(_ button: T, offset: CGFloat, action: @escaping () -> Void) -> T {
            button.frame = NSRect(
                x: panelWidth / 2 + offset - 22, y: 14, width: 44, height: 44)
            button.action = action
            blur.addSubview(button)
            return button
        }

        speedButton = place(TextButton(), offset: -124) { [weak self] in
            guard let self else { return }
            self.speedButton.title = self.onSpeed()
        }
        speedButton.title = speedLabel

        let back = place(GlyphButton(), offset: -62) { [weak self] in
            self?.onSkip(-skipSeconds)
        }
        back.image = symbol("gobackward.10", pointSize: 16, color: Palette.paper)

        playButton = place(GlyphButton(), offset: 0) { [weak self] in
            self?.onToggle()
        }
        playButton.image = pauseImage

        let stop = place(GlyphButton(), offset: 62) { [weak self] in
            self?.onStop()
        }
        stop.image = symbol("stop.fill", pointSize: 16, color: Palette.paper)

        let forward = place(GlyphButton(), offset: 124) { [weak self] in
            self?.onSkip(skipSeconds)
        }
        forward.image = symbol("goforward.10", pointSize: 16, color: Palette.paper)
    }

    private func makeLabel(font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    // MARK: - Visibility

    func show() {
        hideAt = nil
        reposition()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        ensureTimer()
    }

    private func reposition() {
        guard !userMoved, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        programmaticMove = true
        panel.setFrameOrigin(
            NSPoint(
                x: visible.origin.x + (visible.width - panelWidth) / 2,
                y: visible.origin.y + bottomInset))
        programmaticMove = false
    }

    func hide(after delay: TimeInterval = 0) {
        if delay <= 0 {
            hideNow()
        } else {
            hideAt = Date().addingTimeInterval(delay)
        }
    }

    private func hideNow() {
        hideAt = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        }
        wave.idle = true
    }

    // MARK: - State

    func setSource(name: String, icon: NSImage?) {
        sourceName = name
        sourceIcon = icon
        applySource()
    }

    private func applySource() {
        messageMode = false
        nameLabel.alignment = .left
        nameLabel.stringValue = sourceName ?? "…"
        nameLabel.sizeToFit()
        let nameWidth = min(nameLabel.frame.width, panelWidth - 100)
        let iconWidth: CGFloat = sourceIcon != nil ? 34 : 0
        let x0 = (panelWidth - iconWidth - nameWidth) / 2
        if let sourceIcon {
            iconView.image = sourceIcon
            iconView.isHidden = false
            iconView.setFrameOrigin(NSPoint(x: x0, y: 131))
        } else {
            iconView.isHidden = true
        }
        nameLabel.frame = NSRect(
            x: x0 + iconWidth,
            y: 131 + (26 - nameLabel.frame.height) / 2,
            width: nameWidth, height: nameLabel.frame.height)
        timeLabel.stringValue = ""
    }

    func setMessage(_ text: String, status: String = "") {
        messageMode = true
        iconView.isHidden = true
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 20, y: 131, width: panelWidth - 40, height: 24)
        nameLabel.stringValue = text
        timeLabel.stringValue = status
    }

    func setSpeedLabel(_ label: String) {
        speedButton.title = label
    }

    // MARK: - Animation

    private func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func tick() {
        // First run: narrate the model download while the panel waits.
        if messageMode, let status = engine.loadStatus {
            timeLabel.stringValue = status
        }

        if let snap = engine.snapshot() {
            if snap.sessionID != sessionID {
                sessionID = snap.sessionID
                envelopeVersion = -1
            }
            if snap.active {
                if snap.version != envelopeVersion && snap.buffered > 0 {
                    envelopeVersion = snap.version
                    wave.envelope = engine.envelope(buckets: waveBuckets)
                    // First audio has arrived: replace any "warming up" notice.
                    if messageMode && sourceName != nil {
                        applySource()
                    }
                }
                wave.progress = snap.fraction
                if !messageMode {
                    let suffix = snap.synthDone ? "" : "…"
                    timeLabel.stringValue =
                        "\(formatTime(snap.position)) / \(formatTime(snap.buffered))\(suffix)"
                }
                setPlayIcon(paused: snap.paused)
            }
        }

        if let hideAt, Date() >= hideAt {
            if isUserHoldingPanel {
                // Mid-drag (or mouse down on the panel): don't vanish out of
                // the user's hand. Try again after they let go, with a beat
                // to look at where it landed.
                self.hideAt = Date().addingTimeInterval(1.2)
            } else {
                hideNow()
            }
        }
    }

    private var isUserHoldingPanel: Bool {
        NSEvent.pressedMouseButtons & 1 != 0
            && panel.frame.contains(NSEvent.mouseLocation)
    }

    private func setPlayIcon(paused: Bool) {
        let wantPause = !paused
        if wantPause != showingPause {
            showingPause = wantPause
            playButton.image = wantPause ? pauseImage : playImage
        }
    }
}
