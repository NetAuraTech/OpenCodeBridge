#!/usr/bin/env python3
"""Generate the four short, subtle session-event tones (issue #246).

Plain mono 16-bit PCM WAV, 44.1 kHz. Each tone is a single short note
(80-150 ms) with a fast 3 ms attack — an iPhone-notification style "ping" —
plus a short echo train (delayed, quiet copies at 80-160 ms spacing) that
fades out, so each tone reads as one note with a light reverb tail rather
than a melody.

All notes are distinct fundamentals:
  success   A5 (880 Hz) — the bright "ding"
  error     E4 (329.6 Hz) — a low, distinct "boop"
  stopped   C5 (523.3 Hz) — a neutral mid note
  attention A4 (440 Hz) — a softer, lower "tap" than success

The echo train carries partial high content (a high-passed copy of each
echo), the way a real room's reflections do; the dry note stays a pure
sine. Everything is scaled to a low peak (~-11 dBFS) so the sounds read
as a quiet "ping", not an alarm.
"""

import math
import os
import struct
import wave

SR = 44100
PEAK = 0.28  # quiet: ~ -11 dBFS

# The sounds live in the app's asset bundle, one directory up from this
# script (works in the host checkout and in the orb's /workspace alike).
SOUNDS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "sounds")


def _one_pole_highpass(x, coeff=0.75):
    """A crude one-pole high-pass, for the echo copies' shimmer."""
    y = 0.0
    out = []
    for s in x:
        y += coeff * (s - y)
        out.append(y)
    return out


def _note(freq, ms):
    """A sine note with a 3 ms linear attack (no click on start)."""
    n = int(ms / 1000.0 * SR)
    attack_n = max(1, int(3.0 / 1000.0 * SR))
    return [
        math.sin(2 * math.pi * freq * i / SR)
        * (1.0 if i >= attack_n else i / attack_n)
        for i in range(n)
    ]


def _normalize(samples):
    peak = max((abs(s) for s in samples), default=0.0)
    if peak <= 0.0:
        return samples
    scale = 1.0 / peak
    return [s * scale for s in samples]


def tone(path, freq, ms, echoes):
    """Render one note plus its echo train into a mono 16-bit WAV.

    `echoes` is `[(delay_ms, level), ...]` — each entry adds a copy of the
    note at `level` times the note's amplitude. An echo starts at the later
    of `delay_ms` and the dry note's end, plus a 10 ms gap, so echoes never
    start inside the dry note (the note is short; the gap is the rhythm).
    Each copy carries a high-passed partial.
    """
    note = _note(freq, ms)
    n = len(note)
    echo_len = int(10.0 / 1000.0 * SR)
    last_end = max([n] + [
        int(max(delay_ms, ms) / 1000.0 * SR) + echo_len + n
        for delay_ms, _ in echoes])
    buffer = [0.0] * last_end
    buffer[:n] = note
    for delay_ms, level in echoes:
        start = int(max(delay_ms, ms) / 1000.0 * SR) + echo_len
        for i, s in enumerate(_one_pole_highpass(note)):
            buffer[start + i] += level * s
    # A short exponential decay from the tail, so the file ends in silence
    # without a click.
    tail = int(40.0 / 1000.0 * SR)
    prev = buffer[-1] if buffer else 0.0
    buffer.extend(prev * math.exp(-6.0 * i / tail) for i in range(tail))
    frames = _normalize(buffer)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, PEAK * s)) * 32767))
            for s in frames
        ))
    print(f"{path}: {len(frames) / SR * 1000:.0f} ms")


# Turn finished: a bright single "ding" (A5) with a light echo tail.
tone(os.path.join(SOUNDS, "session_success.wav"),
     880.0, 100, [(90, 0.35), (170, 0.18), (250, 0.09)])
# Turn failed: a low, distinct "boop" (E4) — clearly not the success ding.
tone(os.path.join(SOUNDS, "session_error.wav"),
     329.63, 150, [(130, 0.35), (260, 0.18), (390, 0.09)])
# Turn stopped / interrupted: one short, neutral mid note (C5).
tone(os.path.join(SOUNDS, "session_stopped.wav"),
     523.25, 90, [(80, 0.35), (160, 0.18)])
# Permission requested / question asked: a softer, lower "tap" (A4) with a
# wider echo — "attention" without the success brightness.
tone(os.path.join(SOUNDS, "session_attention.wav"),
     440.0, 80, [(110, 0.35), (220, 0.18), (330, 0.09)])
