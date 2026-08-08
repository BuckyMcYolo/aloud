import AVFoundation
import Foundation
import Kokoro

/// Speech engine: incremental synthesis into one seekable stream.
///
/// Kokoro synthesises a whole string in one shot, which would leave a long
/// selection silent while the model works. We split into sentences and
/// synthesise them serially — but every chunk lands in a single growing
/// buffer that one audio stream plays through a cursor. The buffer is the
/// timeline: pause, resume and scrubbing are just cursor moves, and since
/// synthesis runs faster than playback the seekable region stays ahead of
/// the playhead.
final class SpeechEngine {
    struct Snapshot {
        let sessionID: Int
        let position: Double
        let buffered: Double
        let fraction: Double
        let paused: Bool
        let synthDone: Bool
        let version: Int
        let active: Bool
    }

    var voice: String
    var speed: Double

    private var pipeline: KPipeline?
    private let loadLock = NSLock()
    private let synthQueue = DispatchQueue(label: "aloud.synthesis")
    private var session: Session?
    private let sessionLock = NSLock()

    init(voice: String, speed: Double) {
        self.voice = voice
        self.speed = speed
    }

    // MARK: - Model

    static var weightsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aloud/MLX_GPU", isDirectory: true)
    }

    var ready: Bool {
        loadLock.lock()
        defer { loadLock.unlock() }
        return pipeline != nil
    }

    /// Load Kokoro, downloading weights on first run. Blocking; call off-main.
    func load(progress: ((String) -> Void)? = nil) throws {
        loadLock.lock()
        defer { loadLock.unlock() }
        if pipeline != nil { return }

        let dir = Self.weightsDirectory
        let configURL = dir.appendingPathComponent("config.json")
        let weightsURL = dir.appendingPathComponent(ConvertedWeightsLayout.modelFileName)
        let voicesDir = dir.appendingPathComponent("voices", isDirectory: true)
        try FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)

        let base = "https://huggingface.co/mweinbach/Kokoro-82M-Swift/resolve/main/MLX_GPU"
        if !FileManager.default.fileExists(atPath: configURL.path) {
            progress?("Downloading voice model…")
            try Self.download("\(base)/config.json", to: configURL)
        }
        if !FileManager.default.fileExists(atPath: weightsURL.path) {
            progress?("Downloading voice model (310 MB)…")
            try Self.download("\(base)/\(ConvertedWeightsLayout.modelFileName)", to: weightsURL)
        }

        progress?("Loading voice model…")
        let model = try KModel(configURL: configURL, weightsURL: weightsURL)
        let voices = VoiceLoader(baseDirectory: voicesDir, enableDownload: true)
        pipeline = KPipeline(model: model, voices: voices, langCode: "en-us")
    }

    private static func download(_ urlString: String, to dest: URL) throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let tmp = dest.appendingPathExtension("part")
        let data = try Data(contentsOf: url)  // blocking is fine on the synth queue
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    // MARK: - Text chunking

    /// Break text into speakable chunks on sentence boundaries.
    static func splitText(_ text: String) -> [String] {
        let collapsed = text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.isEmpty { return [] }

        let maxChunk = 320
        var pieces: [String] = []

        // Break after sentence punctuation followed by a space. (Swift's
        // Regex has no lookbehind, so this is spelled out by hand.)
        var sentences: [String] = []
        var current = ""
        let breakers: Set<Character> = [".", "!", "?", ";", ":"]
        var previous: Character = " "
        for ch in collapsed {
            if ch == " ", breakers.contains(previous) {
                sentences.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            previous = ch
        }
        if !current.isEmpty { sentences.append(current) }

        for sentence in sentences {
            var raw = sentence.trimmingCharacters(in: .whitespaces)
            // A single sentence can still be enormous. Fall back to a
            // comma/word split so the first audio arrives quickly.
            while raw.count > maxChunk {
                let window = String(raw.prefix(maxChunk))
                var cut = window.lastIndex(of: ",").map { window.distance(from: window.startIndex, to: $0) } ?? -1
                if cut < maxChunk / 3 {
                    cut = window.lastIndex(of: " ").map { window.distance(from: window.startIndex, to: $0) } ?? -1
                }
                if cut <= 0 { cut = maxChunk }
                let idx = raw.index(raw.startIndex, offsetBy: cut)
                pieces.append(String(raw[..<idx]).trimmingCharacters(in: .whitespaces))
                raw = String(raw[idx...]).trimmingCharacters(in: .whitespaces)
            }
            if !raw.isEmpty { pieces.append(raw) }
        }
        return pieces
    }

    // MARK: - Session

    private final class Session {
        static var counter = 0

        let id: Int
        let lock = NSLock()
        var rate: Double = 24_000
        var buf: [Float] = []
        var cursor = 0
        var paused = false
        var synthDone = false
        var stopped = false
        var drained = false
        var version = 0

        init() {
            Session.counter += 1
            id = Session.counter
        }

        func append(_ samples: [Float]) {
            lock.lock()
            buf.append(contentsOf: samples)
            version += 1
            lock.unlock()
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    private func currentSession() -> Session? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session
    }

    // MARK: - Transport

    private(set) var speaking = false

    func stop() {
        guard let s = currentSession() else { return }
        s.lock.lock()
        s.stopped = true
        s.lock.unlock()
    }

    func togglePause() {
        guard let s = currentSession() else { return }
        s.lock.lock()
        s.paused.toggle()
        s.lock.unlock()
    }

    func seek(fraction: Double) {
        guard let s = currentSession() else { return }
        let f = min(1.0, max(0.0, fraction))
        s.lock.lock()
        s.cursor = Int(f * Double(s.buf.count))
        s.lock.unlock()
    }

    func seek(seconds: Double) {
        guard let s = currentSession() else { return }
        s.lock.lock()
        let target = s.cursor + Int(seconds * s.rate)
        s.cursor = min(s.buf.count, max(0, target))
        s.lock.unlock()
    }

    func snapshot() -> Snapshot? {
        guard let s = currentSession() else { return nil }
        s.lock.lock()
        defer { s.lock.unlock() }
        let total = s.buf.count
        return Snapshot(
            sessionID: s.id,
            position: Double(s.cursor) / s.rate,
            buffered: Double(total) / s.rate,
            fraction: total > 0 ? Double(s.cursor) / Double(total) : 0,
            paused: s.paused,
            synthDone: s.synthDone,
            version: s.version,
            active: speaking && !s.stopped)
    }

    /// Coarse RMS envelope of the synthesised audio, for the waveform.
    func envelope(buckets: Int) -> [Double] {
        guard let s = currentSession() else { return Array(repeating: 0, count: buckets) }
        s.lock.lock()
        let buf = s.buf
        s.lock.unlock()

        if buf.isEmpty { return Array(repeating: 0, count: buckets) }
        let window = max(1, buf.count / buckets)
        var out: [Double] = []
        out.reserveCapacity(buckets)
        for i in 0..<buckets {
            let start = i * window
            let end = min(buf.count, start + window)
            if start >= end {
                out.append(0)
                continue
            }
            var sum = 0.0
            for j in start..<end {
                let v = Double(buf[j])
                sum += v * v
            }
            out.append((sum / Double(end - start)).squareRoot())
        }
        let peak = out.max() ?? 1
        let norm = peak > 0 ? peak : 1
        return out.map { min(1.0, $0 / norm) }
    }

    // MARK: - Playback

    func speak(
        _ text: String,
        onDone: (() -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        stop()
        let session = Session()
        sessionLock.lock()
        self.session = session
        sessionLock.unlock()
        speaking = true

        // The serial queue is the join: a new session's work starts only
        // after the previous run() has fully torn down its audio engine.
        synthQueue.async { [weak self] in
            self?.run(text: text, session: session, onDone: onDone, onError: onError)
            if let self, self.currentSession() === session {
                self.speaking = false
            }
        }
    }

    private func run(
        text: String, session: Session,
        onDone: (() -> Void)?, onError: ((Error) -> Void)?
    ) {
        do {
            try load()
            guard let pipeline else { return }

            let pieces = Self.splitText(text)
            if pieces.isEmpty {
                onDone?()
                return
            }

            var audioEngine: AVAudioEngine?

            defer {
                audioEngine?.stop()
            }

            for piece in pieces {
                if session.isStopped { break }
                let result = try pipeline.synthesize(
                    text: piece, voice: voice, speed: Float(speed))
                session.lock.lock()
                session.rate = Double(result.sampleRate)
                session.lock.unlock()
                session.append(result.audio)

                if audioEngine == nil {
                    // Audio starts as soon as the first sentence exists.
                    audioEngine = try startPlayback(session: session)
                }
            }

            session.lock.lock()
            session.synthDone = true
            session.lock.unlock()

            if audioEngine == nil {
                if !session.isStopped { onDone?() }
                return
            }

            while true {
                session.lock.lock()
                let finished = session.drained || session.stopped
                session.lock.unlock()
                if finished { break }
                Thread.sleep(forTimeInterval: 0.05)
            }

            if !session.isStopped { onDone?() }
        } catch {
            if !session.isStopped { onError?(error) }
        }
    }

    private func startPlayback(session: Session) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: session.rate, channels: 1)
        else { throw URLError(.unknown) }

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let frames = Int(frameCount)

            session.lock.lock()
            if session.stopped || session.paused {
                session.lock.unlock()
                for i in 0..<frames { out[i] = 0 }
                return noErr
            }
            let available = session.buf.count - session.cursor
            let n = min(frames, max(0, available))
            if n > 0 {
                session.buf.withUnsafeBufferPointer { ptr in
                    for i in 0..<n { out[i] = ptr[session.cursor + i] }
                }
                session.cursor += n
            }
            if session.synthDone && session.cursor >= session.buf.count {
                session.drained = true
            }
            session.lock.unlock()

            // Synthesis hasn't caught up (or we're done): pad silence.
            for i in n..<frames { out[i] = 0 }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        return engine
    }
}
