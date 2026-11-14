#!/usr/bin/env python3
"""Generate the four short, subtle session-event tones (issue #246).

Plain mono 16-bit PCM WAV, 44.1 kHz. Each note is a sine with a fast attack
(3 ms) and an exponential release, so a note decays instead of clicking.
The file ends in silence. Everything is scaled to a low peak (~-11 dBFS) so
the sounds read as a quiet "ping", not an alarm.
"""

import math
import struct
import wave

SR = 44100
PEAK = 0.28  # quiet: ~ -11 dBFS


def _attack_release(i, n, attack_ms=3.0, release_ms=45.0):
    """Gain in (0, 1]: fast linear attack, exponential release at the tail."""
    attack_n = max(1, int(attack_ms / 1000.0 * SR))
    release_n = max(1, int(release_ms / 1000.0 * SR))
    g = i / attack_n if i < attack_n else 1.0
    if i >= n - release_n:
        g *= math.exp(-3.0 * (i - (n - release_n)) / release_n)
    return max(0.0, min(1.0, g))


def tone(path, notes, gap_ms=0.0, tail_ms=50.0):
    """Render `[(freq, ms), ...]` notes (with a silent [gap_ms] between them)
    into a mono 16-bit WAV."""
    frames = []
    for k, (freq, ms) in enumerate(notes):
        if k > 0 and gap_ms > 0:
            frames.extend([0.0] * int(gap_ms / 1000.0 * SR))
        n = int(ms / 1000.0 * SR)
        for i in range(n):
            frames.append(math.sin(2 * math.pi * freq * i / SR)
                          * _attack_release(i, n))
    # A short exponential decay continuing from the last note sample, so the
    # file ends in silence without a click.
    tail = int(tail_ms / 1000.0 * SR)
    prev = frames[-1] if frames else 0.0
    for i in range(tail):
        frames.append(prev * math.exp(-6.0 * i / tail))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, PEAK * s)) * 32767))
            for s in frames
        ))
    print(f"{path}: {len(frames) / SR * 1000:.0f} ms")


# Turn finished: a soft two-note "ding-dong" chime (G5 -> E5).
tone("/workspace/app/assets/sounds/session_success.wav",
     [(784.0, 130), (659.25, 200)])
# Turn failed: a distinct, lower "dun…dun" — two E4 hits, separated.
tone("/workspace/app/assets/sounds/session_error.wav",
     [(329.63, 150), (329.63, 190)], gap_ms=90)
# Turn stopped / interrupted: one short, mid, neutral blip (B4).
tone("/workspace/app/assets/sounds/session_stopped.wav",
     [(493.88, 170)])
# Permission requested / question asked: a brief double "ding" (A5, A5) —
# a third, clearly different "attention" tone.
tone("/workspace/app/assets/sounds/session_attention.wav",
     [(880.0, 90), (880.0, 120)], gap_ms=70)
