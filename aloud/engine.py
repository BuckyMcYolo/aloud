"""Speech engine: incremental synthesis into one seekable stream.

Kokoro synthesises a whole string in one shot, which would leave a long
selection silent while the model works. We split into sentences and
synthesise them serially — but every chunk lands in a single growing
buffer that one audio stream plays through a cursor. The buffer is the
timeline: pause, resume and scrubbing are just cursor moves, and since
synthesis runs faster than playback the seekable region stays ahead of
the playhead.
"""

from __future__ import annotations

import itertools
import re
import threading
import urllib.request
from pathlib import Path
from typing import Callable

import numpy as np
import sounddevice as sd

MODEL_DIR = Path.home() / ".aloud" / "models"
MODEL_URL = (
    "https://github.com/nazdridoy/kokoro-tts/releases/download/v1.0.0/kokoro-v1.0.onnx"
)
VOICES_URL = (
    "https://github.com/nazdridoy/kokoro-tts/releases/download/v1.0.0/voices-v1.0.bin"
)

# If the user already has kokoro-tts-tool installed, reuse its download.
LEGACY_DIRS = [
    Path.home() / ".kokoro-tts" / "models",
    Path.home() / ".cache" / "kokoro",
]

SENTENCE_BREAK = re.compile(r"(?<=[.!?;:])\s+|\n{2,}")
MAX_CHUNK_CHARS = 320


def split_text(text: str) -> list[str]:
    """Break text into speakable chunks on sentence boundaries."""
    text = re.sub(r"\s+", " ", text.strip())
    if not text:
        return []

    pieces: list[str] = []
    for raw in SENTENCE_BREAK.split(text):
        raw = (raw or "").strip()
        if not raw:
            continue
        # A single sentence can still be enormous (pasted paragraphs without
        # punctuation). Fall back to a comma/word split so the first audio
        # arrives quickly.
        while len(raw) > MAX_CHUNK_CHARS:
            cut = raw.rfind(",", 0, MAX_CHUNK_CHARS)
            if cut < MAX_CHUNK_CHARS // 3:
                cut = raw.rfind(" ", 0, MAX_CHUNK_CHARS)
            if cut <= 0:
                cut = MAX_CHUNK_CHARS
            pieces.append(raw[:cut].strip())
            raw = raw[cut:].strip()
        if raw:
            pieces.append(raw)
    return pieces


def _download(url: str, dest: Path, progress: Callable[[str], None] | None = None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")

    def hook(count, block_size, total):
        if progress and total > 0:
            pct = min(100, int(count * block_size * 100 / total))
            progress(f"Downloading {dest.name} — {pct}%")

    urllib.request.urlretrieve(url, tmp, reporthook=hook)
    tmp.rename(dest)


def ensure_models(progress: Callable[[str], None] | None = None) -> tuple[Path, Path]:
    """Return paths to the model and voice files, downloading them if needed."""
    model = MODEL_DIR / "kokoro-v1.0.onnx"
    voices = MODEL_DIR / "voices-v1.0.bin"

    for legacy in LEGACY_DIRS:
        lm, lv = legacy / "kokoro-v1.0.onnx", legacy / "voices-v1.0.bin"
        if lm.exists() and lv.exists():
            return lm, lv

    if not model.exists():
        _download(MODEL_URL, model, progress)
    if not voices.exists():
        _download(VOICES_URL, voices, progress)
    return model, voices


class _Session:
    """One read-aloud: a growing sample buffer plus a play cursor."""

    _ids = itertools.count(1)

    def __init__(self, rate: int = 24000):
        self.id = next(_Session._ids)
        self.rate = rate
        self.lock = threading.Lock()
        self.buf = np.zeros(0, dtype=np.float32)
        self.cursor = 0
        self.paused = False
        self.synth_done = False
        self.stop = threading.Event()
        self.version = 0  # bumped on every append, so the HUD knows to redraw

    def append(self, samples):
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        with self.lock:
            self.buf = np.concatenate([self.buf, samples])
            self.version += 1


class Engine:
    """Loads Kokoro lazily and plays text through the default output device."""

    def __init__(
        self, voice: str = "af_heart", speed: float = 1.0, lang: str = "en-us"
    ):
        self.voice = voice
        self.speed = speed
        self.lang = lang
        self._kokoro = None
        self._lock = threading.Lock()
        self._session: _Session | None = None
        self._thread: threading.Thread | None = None

    # -- model ---------------------------------------------------------------

    def load(self, progress: Callable[[str], None] | None = None):
        with self._lock:
            if self._kokoro is not None:
                return
            model, voices = ensure_models(progress)
            if progress:
                progress("Loading voice model…")
            # Imported here so the menu bar appears before onnxruntime loads.
            from kokoro_onnx import Kokoro

            self._kokoro = Kokoro(str(model), str(voices))

    @property
    def ready(self) -> bool:
        return self._kokoro is not None

    def voices(self) -> list[str]:
        if self._kokoro is None:
            return []
        try:
            return sorted(self._kokoro.get_voices())
        except Exception:
            return []

    # -- transport -------------------------------------------------------------

    @property
    def speaking(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def stop(self):
        session = self._session
        if session is not None:
            session.stop.set()

    def pause(self):
        session = self._session
        if session is not None:
            with session.lock:
                session.paused = True

    def resume(self):
        session = self._session
        if session is not None:
            with session.lock:
                session.paused = False

    def toggle_pause(self):
        session = self._session
        if session is not None:
            with session.lock:
                session.paused = not session.paused

    def seek_fraction(self, fraction: float):
        """Jump to a position expressed as a fraction of the synthesised audio."""
        session = self._session
        if session is None:
            return
        fraction = min(1.0, max(0.0, float(fraction)))
        with session.lock:
            session.cursor = int(fraction * len(session.buf))

    def seek_seconds(self, delta: float):
        """Skip forward or back, clamped to what has been synthesised."""
        session = self._session
        if session is None:
            return
        with session.lock:
            target = session.cursor + int(delta * session.rate)
            session.cursor = min(len(session.buf), max(0, target))

    def snapshot(self) -> dict | None:
        """Transport state for the HUD, polled from its animation timer."""
        session = self._session
        if session is None:
            return None
        with session.lock:
            total = len(session.buf)
            return {
                "session": session.id,
                "position": session.cursor / session.rate,
                "buffered": total / session.rate,
                "fraction": (session.cursor / total) if total else 0.0,
                "paused": session.paused,
                "synth_done": session.synth_done,
                "version": session.version,
                "active": self.speaking and not session.stop.is_set(),
            }

    def envelope(self, buckets: int = 48) -> list[float]:
        """Coarse RMS envelope of the synthesised audio, for the waveform."""
        session = self._session
        if session is None:
            return [0.0] * buckets
        with session.lock:
            buf = session.buf  # appends replace the array, so this ref is stable
        n = len(buf)
        if n == 0:
            return [0.0] * buckets
        window = max(1, n // buckets)
        usable = window * buckets
        if usable > n:
            buf = np.pad(buf, (0, usable - n))
        out = np.sqrt(np.mean(np.square(buf[:usable].reshape(buckets, window)), axis=1))
        peak = float(out.max()) or 1.0
        return [min(1.0, float(v) / peak) for v in out]

    # -- playback ------------------------------------------------------------

    def speak(
        self,
        text: str,
        on_done: Callable[[], None] | None = None,
        on_error: Callable[[Exception], None] | None = None,
    ):
        """Speak text on a background thread. Replaces anything already playing."""
        self.stop()
        if self._thread is not None:
            self._thread.join(timeout=2.0)

        # The session travels with the thread: a rapid second speak() replaces
        # self._session, and the old thread must keep honouring its own stop.
        session = _Session()
        self._session = session
        self._thread = threading.Thread(
            target=self._run,
            args=(text, session, on_done, on_error),
            daemon=True,
        )
        self._thread.start()

    def _open_stream(self, rate, callback, finished):
        def build():
            stream = sd.OutputStream(
                samplerate=rate,
                channels=1,
                dtype="float32",
                callback=callback,
                finished_callback=finished.set,
            )
            stream.start()
            return stream

        try:
            return build()
        except sd.PortAudioError:
            # macOS audio devices come and go (AirPods, Continuity iPhone
            # mics, USB DACs) and PortAudio's device snapshot goes stale when
            # they do — the open fails until PortAudio is reinitialised.
            sd._terminate()
            sd._initialize()
            return build()

    def _run(self, text, session, on_done, on_error):
        try:
            self.load()
            pieces = split_text(text)
            if not pieces:
                if on_done:
                    on_done()
                return

            finished = threading.Event()

            def callback(outdata, frames, _time, _status):
                if session.stop.is_set():
                    raise sd.CallbackStop
                with session.lock:
                    if session.paused:
                        outdata.fill(0)
                        return
                    avail = len(session.buf) - session.cursor
                    n = min(frames, max(0, avail))
                    if n:
                        outdata[:n, 0] = session.buf[
                            session.cursor : session.cursor + n
                        ]
                        session.cursor += n
                    drained = session.synth_done and session.cursor >= len(session.buf)
                if n < frames:
                    # Synthesis hasn't caught up (or we're done): pad silence.
                    outdata[n:].fill(0)
                if drained:
                    raise sd.CallbackStop

            stream = None
            try:
                for piece in pieces:
                    if session.stop.is_set():
                        break
                    samples, rate = self._kokoro.create(
                        piece, voice=self.voice, speed=self.speed, lang=self.lang
                    )
                    session.rate = rate
                    session.append(samples)
                    if stream is None:
                        # Audio starts as soon as the first sentence exists.
                        stream = self._open_stream(rate, callback, finished)

                with session.lock:
                    session.synth_done = True

                if stream is None:
                    if not session.stop.is_set() and on_done:
                        on_done()
                    return

                while not finished.is_set() and not session.stop.is_set():
                    finished.wait(0.05)
            finally:
                # Close on every path — a leaked stream keeps its callback
                # alive forever and sours PortAudio for the next read.
                if stream is not None:
                    if not finished.is_set():
                        stream.abort()
                    stream.close()

            if not session.stop.is_set() and on_done:
                on_done()
        except Exception as exc:  # noqa: BLE001 - reported through the HUD
            if on_error:
                on_error(exc)
