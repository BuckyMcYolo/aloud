import AppKit

/// `--selftest "text"`: synthesize and play without any UI, print timings,
/// exit. Lets the whole engine path be verified from a terminal.
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--selftest" {
    let text =
        CommandLine.arguments.count >= 3
        ? CommandLine.arguments[2]
        : "This is the Aloud self test."
    let engine = SpeechEngine(voice: "af_heart", speed: 1.0)

    print("loading model…")
    let loadStart = Date()
    try engine.load { print("  \($0)") }
    print(String(format: "loaded in %.1fs", -loadStart.timeIntervalSinceNow))

    let done = DispatchSemaphore(value: 0)
    var failure: Error?
    let synthStart = Date()
    engine.speak(
        text,
        onDone: { done.signal() },
        onError: {
            failure = $0
            done.signal()
        })
    done.wait()
    if let failure {
        print("FAILED: \(failure)")
        exit(1)
    }
    let snapshot = engine.snapshot()
    print(String(
        format: "spoke %.1fs of audio in %.1fs wall",
        snapshot?.buffered ?? 0, -synthStart.timeIntervalSinceNow))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
