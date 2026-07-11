# /// script
# dependencies = ["numpy"]
# ///
"""Generate a diagnostic tone-ladder WAV for testing which frequencies
survive the ting's playback engine. Flash as 1.wav, trigger, record the
line-out, FFT the result. Usage: uv run make_toneladder.py [out.wav]
"""
import sys
import wave

import numpy as np

SR = 48000
TONES = [1000, 10000, 14000, 16000, 17000, 17500, 18000, 18500, 19000]
SEG, GAP, FADE = int(0.4 * SR), int(0.1 * SR), int(0.01 * SR)

env = np.ones(SEG)
env[:FADE] = 0.5 * (1 - np.cos(np.pi * np.arange(FADE) / FADE))
env[-FADE:] = env[:FADE][::-1]
t = np.arange(SEG) / SR

parts = []
for f in TONES:
    parts.append(0.85 * env * np.sin(2 * np.pi * f * t))
    parts.append(np.zeros(GAP))
sig = np.concatenate(parts)
pcm = (sig * 32767).astype("<i2")

out = sys.argv[1] if len(sys.argv) > 1 else "toneladder.wav"
with wave.open(out, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(pcm.tobytes())
print(f"wrote {out}: {len(sig)/SR:.2f}s, tones={TONES}")
