# tingle design

macOS menu bar daemon that turns the Teenage Engineering EP-2350 "ting" into
a dictation and macro device. Two halves: a Swift app on the Mac, and a
MicroPython event engine that tingle installs on the device itself.

## How the device is extended

The ting executes `main.py` from its writable FAT disk (`TINGDISK`) at boot
(verified fw 1.0.4; `boot.py` is not honored). "Flash EP" writes four tone
WAVs plus [device/tingle_main.py](device/tingle_main.py), which chain-loads the
stock `/rom/main.py` (all TE behavior preserved) and wraps its event
callback. Deleting `main.py` from the disk restores a 100% stock device. No
firmware is ever modified.

The wrapped callback:

- prints `EVT …` lines over USB CDC serial (vbus-guarded; the serial backend
  is a passive line reader — no REPL interaction),
- plays two-tone chirps through the line-out so events are detectable over a
  bare 3.5mm connection,
- guards itself with a crash recorder: any exception dumps a traceback to
  `/fat/tingle_crash.log` and restores the stock callback.

## Chirp protocol

Tones 1–4 (slots 0–3) are 80ms sine bursts at 17.5/18/18.5/19 kHz —
inaudible, and far above speech, so they coexist with dictation audio.
Chirp pairs play ~130ms apart through an on-device queue (beacons defer to
event chirps; sequences never interleave).

| Signal | Meaning |
|---|---|
| single tone N | white press in mode N (stock sample playback) |
| tone N → (N+1)%4 | mode changed to N (green) |
| tone N → (N−1)%4 | FX preset changed, in mode N (orange) |
| tone 0 → 2 (fixed) | handle squeezed (device mic live) |
| tone 2 → 0 (fixed) | handle released |
| tone 1 → 3 (fixed) | beacon heartbeat (~2s), handle released |
| tone 3 → 1 (fixed) | beacon heartbeat, handle held |

The relative (±1) codes can never produce the fixed (±2) pairs, so decoding
is collision-free. Beacons carry handle state so a lost trigger chirp
self-heals within one period: the Mac synthesizes the missing edge when a
beacon contradicts its state — from chirp-decoded beacons only (serial `EVT
beacon` lines are stateless).

The beacon also drives zero-config discovery: the coordinator scans ranked
line-in candidates (~5s dwell) until a beacon arrives, audits the top-ranked
jack before locking (chirps bleed across the Cubilux's MIC IN/Line IN), and
tracks freshness (stale after ~6s; rescan after ~15s more). Serial presence
always preempts audio. Beacons do not prevent the device's battery
power-save: an idle ting sleeps after 5 minutes and reads as absent — honest.

## Trigger sensing (device)

The trigger has two nearly-independent sensors: a tactile switch
(`ui.sw(4)`; trips at ~2% travel, sticky release around 40–60%) and an
analog shaft (`ui.handle_raw()`, 0–1; fast shallow clicks barely move it).
The payload derives edges from the switch with a 3-tick (~50ms) stability
debounce, plus two guards: a shaft-trust release (switch claims held, shaft
< 0.05 → release) and a stuck-latch (after a shaft-forced release, no press
is believed until the switch physically opens — prevents ADC noise from
flapping phantom presses).

## Audio detection (Mac)

Goertzel bank at the four tone frequencies over 20ms windows (50Hz bins;
targets land on bin centers at 48kHz). A hit requires ≥8dB over ±250Hz guard
bins and over the in-band median; clipped windows demand 20dB dominance
instead of rejection (hot line-in gain clips the tones themselves). Bursts
are duration-gated (clicks and sustained program audio rejected), paired
into chirps within a 200ms window, with a 150ms refractory after events —
beacons never enter refractory. Auto-selected input: line-in-named devices
ranked first; aggregates, virtual devices, and the built-in mic are never
candidates.

## Dictation (Mac, macOS 26+)

`SpeechAnalyzer`/`SpeechTranscriber` with `[.volatileResults, .fastResults]`.
Squeeze starts a session; audio is captured from the squeeze itself (tap
attaches before recognizer setup; a ~2s pre-roll replays into the analyzer
once live). In serial mode a shared capture engine stays warm for 60s
between sessions. Results are consumed into a latest-hypothesis holder; a
separate typing worker converges the screen via keystroke edits
(TranscriptTyper: minimal backspace+append deltas, corrections strictly
bounded to the volatile region; external typing freezes it). Release
finalizes with a 5s hard timeout; startup-wedged sessions are force-
abandoned after 10s. Completed takes stack (cap 10): each green press erases
exactly the characters of one more take (same app, ≤5min). Consecutive takes
in the same app auto-join with a space.

## Configuration

Literate TOML at `~/Library/Application Support/tingle/config.toml`,
live-reloaded; the shipped default file is its own documentation. Mappings:
`mode1`–`mode4`, `modeChange`, `fxChange`, `triggerDown`, `triggerUp` →
actions `dictate`, `eraseDictation`, `keystroke`, `keyHold` and `shell`
(multiline scripts via TOML `\'\'\'` strings). `vocabulary` biases dictation
via `AnalysisContext.contextualStrings`. tingle never writes the file after
creation — menu-driven state (the pinned input device) lives in
UserDefaults so user comments survive. Defaults: trigger = dictate, orange
= enter, green = erase last take, white unmapped (a commented "summon your
agent" script ships in the template).

## Distribution

`scripts/bundle.sh` assembles `tingle.app` (SwiftPM release build + Info.plist
+ resource bundle). Release flow (`.github/workflows/release.yml`): tag →
tests → Developer ID sign → notarize → GitHub Release → bump the cask
(template: [packaging/tingle.rb](packaging/tingle.rb)) in
`tutorintelligence/homebrew-tap`. Blocked on Apple Developer enrollment; until
then ad-hoc signing re-prompts TCC on every rebuild.

## Roadmap

1. Custom language model (`SFCustomLanguageModelData`: phrases, templates,
   custom pronunciations) for domain adaptation beyond contextual strings.
2. Apple Developer enrollment → signing/notarization/tap → first release.
3. Exploration: the firmware's ADC event messages (type 0x1X) may carry
   higher-rate handle data (merged-tap recovery, analog gestures).

## Device reference (fw 1.0.4, all measured on hardware)

- FAT disk: `1.wav`–`4.wav` override sample slots (WAV up to 96kHz, ~1MB
  total), `config.json` overrides FX presets (recovery: hold green+white at
  boot), `main.py` executes at boot. The firmware's view of the disk is
  snapshotted at boot; host writes are invisible until restart.
- Serial REPL: CDC at 115200; `\r\x03\x03` interrupts to a live namespace
  (`ui`, `spl`, `fx`, `sam_pos`, `fx_pos`). `spl.trigger(-1, slot, True)`
  plays a slot; `trigger(…, False)` cannot stop a oneshot. `spl.load_wav`
  accepts a hidden slot 4 but `trigger` refuses it. No `machine` module;
  Ctrl+D re-enumerates USB.
- Engine ticks ~61Hz drive the callback (type 3); button events are type
  1/2 with val 0=white, 1=green, 2=orange (green/orange act only with the
  handle released). ADC events are type 0x1X (unused).
- Line out 2 VRMS, scaled by the volume knob; the engine reproduces up to
  19kHz at full level. Factory FX presets inject sample playback after
  pitch effects, so tones survive PIXIE/ROBOT.
- Green/orange state changes commit ~10 ticks (~164ms) after the press
  (stock priming debounce).
