// Renders the Aloud app icon: the HUD's waveform, in its palette, on the
// classic macOS squircle. Run: swift generate.swift <output.png>
import AppKit

let canvas: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Squircle plate: Apple's Big Sur geometry — 824pt square on a 1024 canvas.
let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
let inkTop = NSColor(srgbRed: 0.125, green: 0.125, blue: 0.170, alpha: 1)
let inkBottom = NSColor(srgbRed: 0.050, green: 0.050, blue: 0.080, alpha: 1)
NSGradient(starting: inkTop, ending: inkBottom)!.draw(in: squircle, angle: -90)

// The waveform: lit bars behind the playhead, shadow bars ahead — the HUD
// in miniature.
let signal = NSColor(srgbRed: 0x9A / 255, green: 0x8C / 255, blue: 0xF0 / 255, alpha: 1)
let shadow = NSColor(srgbRed: 0x44 / 255, green: 0x3C / 255, blue: 0x6B / 255, alpha: 1)
let levels: [CGFloat] = [0.34, 0.58, 0.96, 0.74, 0.46, 0.82, 0.38]
let litCount = 3

let barWidth: CGFloat = 62
let gap: CGFloat = 30
let totalWidth = CGFloat(levels.count) * barWidth + CGFloat(levels.count - 1) * gap
let maxHeight: CGFloat = 460
var x = (canvas - totalWidth) / 2

for (i, level) in levels.enumerated() {
    let height = max(barWidth, level * maxHeight)
    let bar = NSRect(x: x, y: (canvas - height) / 2, width: barWidth, height: height)
    (i < litCount ? signal : shadow).set()
    NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
