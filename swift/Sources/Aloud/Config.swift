import Foundation

/// Settings shared with the Python version: same file, same keys, so the two
/// implementations can be swapped without losing preferences.
struct Config {
    var voice = "af_heart"
    var speed = 1.0
    var hotkey = "<alt>+<shift>+s"
    var restoreClipboard = true
    var liquidGlass = false

    static let fileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".aloud/config.json")

    static func load() -> Config {
        var config = Config()
        guard let data = try? Data(contentsOf: fileURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }
        if let v = json["voice"] as? String { config.voice = v }
        if let s = json["speed"] as? Double { config.speed = s }
        if let h = json["hotkey"] as? String { config.hotkey = h }
        if let r = json["restore_clipboard"] as? Bool { config.restoreClipboard = r }
        if let g = json["liquid_glass"] as? Bool { config.liquidGlass = g }
        return config
    }

    func save() {
        let json: [String: Any] = [
            "voice": voice,
            "speed": speed,
            "hotkey": hotkey,
            "restore_clipboard": restoreClipboard,
            "liquid_glass": liquidGlass,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL)
    }
}

let featuredVoices: [(label: String, id: String)] = [
    ("Heart — warm, female", "af_heart"),
    ("Bella — bright, female", "af_bella"),
    ("Nicole — soft, female", "af_nicole"),
    ("Adam — even, male", "am_adam"),
    ("Michael — low, male", "am_michael"),
    ("Emma — British, female", "bf_emma"),
    ("George — British, male", "bm_george"),
]

let speedPresets: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

// Offered in the Shortcut menu. Combos stay in pynput syntax so config.json
// remains compatible with the Python implementation.
let hotkeyPresets: [String] = [
    "<alt>+<shift>+s",
    "<ctrl>+s",
    "<ctrl>+<shift>+s",
    "<cmd>+<shift>+s",
    "<ctrl>+<alt>+s",
    "<alt>+<shift>+r",
]

func speedLabel(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))×" : "\(value)×".replacingOccurrences(of: ".0×", with: "×")
}
