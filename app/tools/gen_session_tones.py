#!/usr/bin/env python3
"""Generate the four short, subtle session-event tones (issue #246).

Plain mono 16-bit PCM WAV, 44.1 kHz. Each tone is a single struck bell —
one note, never a melody — in the style of herdr's notification sounds
(herdrdev/herdr, Apache-2.0, `assets/sounds/*.mp3`): a fundamental plus a
few low partials (the higher partials decay faster, giving the "shimmer"
of a struck bell), a short ~8 ms raised-cosine attack (no click), and one
smooth exponential decay that does all the work of the "reverb" — the
audible tail is a single smooth curve, with no repeated echoes.

The four events are distinct fundamentals, so the outcomes stay
tellable apart:
  success   A5 (880 Hz)  — bright "ding", quick decay (like herdr "done")
  error     E4 (329.6 Hz) — low, drawn-out "boop"
  stopped   C5 (523.3 Hz) — short, neutral, snappy note
  attention E5 (659.3 Hz) — rich chime (strong 3rd partial, like herdr
                            "request") with a drawler tail

Everything is normalized to a low peak (~-11 dBFS) so the sounds read as
a quiet "ping", not an alarm.
"""

import math
import os
import struct
import wave

SR = 44100
PEAK = 0.28  # quiet: ~ -11 dBFS


def bell(path, f0, partials, tau_ms, length_ms=650.0, attack_ms=8.0):
    """Render one struck bell into a mono 16-bit WAV.

    `partials` is `[(ratio, amplitude), ...]` (the fundamental is
    `(1.0, 1.0)`). The partial at `ratio` decays with time constant
    `tau_ms / ratio` — the higher partials die faster, which is what makes
    a bell shimmer rather than hum. `tau_ms` is the fundamental's time
    constant; the whole tone is one smooth exponential decay.
    """
    n = int(length_ms / 1000.0 * SR)
    attack_n = max(1, int(attack_ms / 1000.0 * SR))
    tau = tau_ms / 1000.0
    frames = []
    for i in range(n):
        t = i / SR
        g = 1.0
        if i < attack_n:
            # Raised-cosine attack: smooth on both ends, no click.
            g = 0.5 - 0.5 * math.cos(math.pi * i / attack_n)
        s = 0.0
        for ratio, amp in partials:
            s += amp * math.exp(-t / (tau / ratio)) * \
                math.sin(2 * math.pi * f0 * ratio * t)
        frames.append(s * g)
    # Normalize to the shared peak (the envelope + partial mix already
    # shapes the tone; this keeps every file equally loud).
    peak = max(abs(s) for s in frames) or 1.0
    scale = PEAK / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, scale * s)) * 32767))
            for s in frames
        ))
    print(f"{path}: {n / SR * 1000:.0f} ms")


# The sounds live in the app's asset bundle, one directory up from this
# script (works in the host checkout and in the orb's /workspace alike).
SOUNDS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "assets", "sounds")

# Turn finished: a bright pure "ding" (A5), quick decay — like herdr "done".
bell(os.path.join(SOUNDS, "session_success.wav"),
     880.0, [(1.0, 1.0), (2.0, 0.15), (3.0, 0.08)], 120.0, 600.0)
# Turn failed: a low, drawn-out "boop" (E4) — the only low tone; a long,
# drawler decay marks it as a bad outcome.
bell(os.path.join(SOUNDS, "session_error.wav"),
     329.63, [(1.0, 1.0), (2.0, 0.25), (4.0, 0.10)], 300.0, 800.0)
# Turn stopped / interrupted: one short, neutral, snappy note (C5).
bell(os.path.join(SOUNDS, "session_stopped.wav"),
     523.25, [(1.0, 1.0), (2.0, 0.10)], 100.0, 500.0)
# Permission requested / question asked: a rich chime (E5) with a strong
# 3rd partial — like herdr "request" — and a drawler tail: "attention".
bell(os.path.join(SOUNDS, "session_attention.wav"),
     659.25, [(1.0, 1.0), (3.0, 0.50), (2.0, 0.12)], 250.0, 700.0)
