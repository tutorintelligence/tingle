# tingle design

macOS menu bar daemon that turns the Teenage Engineering EP-2350 "ting" into
a dictation and macro device. Two halves: a Swift app on the Mac, and a
MicroPython event engine that tingle installs on the device itself.

## How the device is extended

The ting executes `main.py` from its writable FAT disk (`TINGDISK`) at boot
(verified fw 1.0.4; `boot.py` is not honored). "Flash EP" writes four coded
symbol WAVs plus [device/tingle_main.py](device/tingle_main.py), which chain-loads the
stock `/rom/main.py` (all TE behavior preserved) and wraps its event
callback. Deleting `main.py` from the disk restores a 100% stock device. No
firmware is ever modified.

The wrapped callback:

- prints `EVT …` lines over USB CDC serial (vbus-guarded; the serial backend
  is a passive line reader — no REPL interaction),
- plays coded symbol words through the line-out so events are detectable
  over a bare 3.5mm connection,
- guards itself with a crash recorder: any exception dumps a traceback to
  `/fat/tingle_crash.log` and restores the stock callback.

## Signaling protocol

The four sample slots hold 25ms linear-chirp symbols (SymbolSet.swift is
the air-gap contract shared by the flasher and the decoder): two disjoint
ultrasonic bands (16.5–17.9k and 18.1–19.5 kHz) × two sweep directions —
inaudible and far above speech, so they coexist with dictation audio.

Every event is a **codeword of four symbols**, ~29ms apart (2 engine
ticks) through the on-device queue — beacons defer to event words;
sequences never interleave. The codebook is a Reed–Solomon [4,2] code
over GF(4): 16 codewords with minimum Hamming distance 3, so the decoder
**corrects any single corrupted symbol and rejects anything further** —
noise or interference cannot turn one button into another, it can only
(rarely) cost a word. A word occupies ~110ms on the wire.

| Codeword message | Meaning |
|---|---|
| beaconReleased / beaconHeld | heartbeat (~2s), carries handle state |
| triggerDown / triggerUp | handle squeezed / released |
| white1–white4 | white press in mode 1–4 |
| mode1–mode4 | mode changed (green) |
| fxChanged | FX preset changed (orange) |

Beacons carry handle state so a lost trigger word self-heals within one
period: the Mac synthesizes the missing edge when a beacon contradicts
its belief — from decoded beacon words only (serial `EVT beacon` lines
are stateless).

The beacon also drives zero-config discovery: the coordinator scans ranked
line-in candidates until a beacon arrives, audits the top-ranked jack
before locking (chirps bleed across the Cubilux's MIC IN/Line IN), and
tracks freshness (stale after ~6s; rescan after ~15s more). The 7s dwell
fits worst-case pilot acquisition at ANY beacon phase (spin-up + up to one
full period waiting + two more periods to lock), and an acquisition hold
extends it while provisional beacons are arriving — the scan never rotates
away one beacon short of a lock. The level a lock settles at is remembered
across backend and app restarts (seeded into each fresh detector), so a
wake-from-sleep usually fast re-locks on a single beacon. When a lock goes
quiet for good (the ting slept), the scan CAMPS on the device it was
locked to — one continuous capture, no rotation (rotation restarted the
engine every dwell and blinked the macOS mic indicator all night) — with
a rare sweep of the other candidates (~5min) in case the ting was
re-plugged to a different jack while asleep. Serial presence
always preempts audio. Beacons do not prevent the device's battery
power-save: an idle ting sleeps after 5 minutes and reads as absent — honest.

## Trigger sensing (device)

The trigger exposes three firmware signals: a tactile switch (`ui.sw(4)`,
closes at ~2% travel — a hair trigger at the top of the stroke), the raw
shaft ADC, and TE's processed position (`ui.handle()`, 0–1, rate-limited
to ~0.35/s). The payload triggers on **full depression** using the
processed signal, with a rate-based fast path for mashes (the processed
signal lags a fast squeeze by ~300ms):

- **press**: `handle() ≥ 0.90` (slow squeeze — the signal tracks the
  finger, so the bottom click feels instant), OR switch closed while the
  signal is climbing ≥0.04/tick for 3 ticks (a signature that only
  exists mid-mash; fires ~45ms after the physical click);
- **release**: `handle() ≤ 0.60` while genuinely descending (2 falling
  ticks — a mash's mid-climb stall must not read as a release), or the
  signal fully returned (≤0.05);
- 3-tick stability confirmation on every edge.

## Audio detection (Mac)

Matched-filter detection (SymbolDetector.swift): each band is
heterodyned to baseband (carriers chosen with exact 64-sample periods at
48kHz), decimated 48k→3k through a polyphase FIR, and slid against the
band's two decimated chirp templates with normalized complex
correlation. A symbol is a dominant correlation peak (~19dB of
time-bandwidth processing gain); peaks emit on 25% decay so word-rate
symbol trains resolve. Symbols assemble into words (gap-validated), and
words decode to the nearest codeword (distance ≤1).

The decoder is **pilot-locked**: it emits nothing until three beacon
words arrive on a plausible period (1.2–4.5s) at consistent level
(±6dB, above an absolute plausibility floor) — line noise cannot fake a
periodic pilot. Losing the pilot for ~3 periods (device asleep,
unplugged) unlocks and mutes the decoder; a single beacon at the
remembered level fast re-locks after sleep. The pilot's measured level
continuously calibrates a credibility gate: words far quieter than the
device's demonstrated output are discarded. Auto-selected input:
line-in-named devices ranked first; aggregates, virtual devices, and the
built-in mic are never candidates.

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
exactly the characters of one more take (same app, ≤5min, and only while
nothing has moved the text since — a real keystroke or click after the
take invalidates erase rather than backspacing over the user's own
content). Consecutive takes in the same app auto-join with a space.

### Rewrite pass (`[rewrite]` in config, on by default)

After a take finalizes, Apple's on-device Foundation model (Apple
Intelligence, macOS 26+) polishes it in place: punctuation, repeated-word
dedup, vocabulary-aware mis-transcription repair, optional symbol-speak
("dash dash force" → `--force`). Division of labor: everything mechanical
is deterministic code — um/uh/er stripping is a regex, model preambles and
markdown are stripped in post — and the model only does judgment work.
The transcript is sent wrapped in `<transcript>` tags as data, never as a
message, and an acceptability gate rejects degenerate outputs (answers,
refusals, censored profanity — every profane token in must come out, same
count; word retention ≥0.35; bounded growth). A rejected output degrades
to the filler-stripped text; a no-op applies nothing. The polish lands
~1-3s after release as a single prefix-cut keystroke edit (delete back to
the first changed character, retype the rest — backspaces cannot reach
past a common suffix, so no other diff shape is valid). The pending
rewrite is cancelled by anything that moves the world: a new squeeze,
erase, send, app switch, or ANY real keystroke or mouse click (a global
input monitor watches for them; tingle's own synthetic events are tagged
via CGEventSource userData and ignored). The menu bar icon shows a blue
dot while the model runs. Eligibility band: 4-1000 words (the model's
4,096-token context window).

## Configuration

Two TOML files in `~/Library/Application Support/tingle/`, layered:

- `default-config.toml` — the full literate defaults, REWRITTEN by the app
  on every launch so it always documents the running version. A mirror,
  not a source: the app parses the embedded template, never this file, so
  a mangled mirror can't break anything. Browse it, copy from it.
- `config.toml` — the user's file, containing only what they change.
  tingle writes a near-empty starter once and never touches it again
  (menu-driven state lives in UserDefaults so user comments survive).
  Live-reloaded on save.

Merge semantics are plain per-key precedence: a key in config.toml wins
wholesale (lists and inline action tables included — no bleed-through);
section tables ([mappings], [replacements], [rewrite]) merge per
contained key, so overriding one mapping keeps the rest. Where different
semantics are wanted, the schema provides them instead of merge magic:
`vocabulary` is the built-in biasing list and `extraVocabulary` is the
user's additions, concatenated (deduped) at load — so built-in list
updates keep flowing to configs that only add words.

Mappings: `mode1`–`mode4`, `modeChange`, `fxChange`, `triggerDown`,
`triggerUp` → actions `dictate`, `eraseDictation`, `keystroke`, `keyHold`
and `shell` (multiline scripts via TOML `\'\'\'` strings). Vocabulary
biases dictation via `AnalysisContext.contextualStrings`. Defaults:
trigger = dictate, orange = enter, green = erase last take, white =
summon-agent script.

## Distribution

`scripts/bundle.sh` assembles `tingle.app` (SwiftPM release build + Info.plist
+ resource bundle) and signs it: Developer ID with hardened runtime, secure
timestamps, and entitlements (mic, Apple Events); Sparkle's nested
executables are signed inside-out. Release flow
(`.github/workflows/auto-release.yml`, on every push to main): version from
the merge subject → build → sign → notarize + staple → Sparkle-signed
appcast → GitHub Release → bump the cask in `tutorintelligence/homebrew-tap`.
The stable signing identity is what lets TCC grants survive updates.

## Roadmap

1. Custom language model (`SFCustomLanguageModelData`: phrases, templates,
   custom pronunciations) for domain adaptation beyond contextual strings.
2. Exploration: the firmware's ADC event messages (type 0x1X) may carry
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
