# /// script
# dependencies = ["numpy"]
# ///
"""Generate the four mode-tone WAVs (1.wav-4.wav) that FLASH EP places on
the TINGDISK. 120ms near-ultrasonic sine bursts, one per sample slot.
Usage: uv run make_mode_tones.py [outdir]
"""
import sys
import wave
from pathlib import Path

import numpy as np

SR = 48000
FREQS = [17500, 18000, 18500, 19000]
DUR, FADE = int(0.08 * SR), int(0.01 * SR)

env = np.ones(DUR)
env[:FADE] = 0.5 * (1 - np.cos(np.pi * np.arange(FADE) / FADE))
env[-FADE:] = env[:FADE][::-1]
t = np.arange(DUR) / SR

outdir = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
for i, f in enumerate(FREQS, start=1):
    # 0.30: 0.85 clipped hot line-in captures (2VRMS out); 40dB+ SNR margin remains.
    sig = 0.30 * env * np.sin(2 * np.pi * f * t)
    pcm = (sig * 32767).astype("<i2")
    with wave.open(str(outdir / f"{i}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{i}.wav: {f} Hz, {DUR*1000//SR}ms, {len(pcm)*2/1024:.0f} KB")
