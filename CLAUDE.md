# tingle — agent guide

macOS menu bar app that turns the Teenage Engineering EP-2350 "ting" into a
dictation/macro device. Swift (SwiftPM) on the Mac + a MicroPython payload
that runs on the device itself. See DESIGN.md for architecture and the chirp
protocol; README.md for user-facing docs.

## Build, test, run

```sh
swift build                      # compile
swift run tingle-tests            # Swift unit tests (no XCTest: bare CLT works)
python3 tools/test_payload.py    # device event-engine unit tests
scripts/bundle.sh                # assemble dist/tingle.app (ad-hoc unless CODESIGN_IDENTITY set)
swift run tingle                  # run the menu bar app (dev)
```

CI (.github/workflows/ci.yml) runs all of the above plus a payload-sync
check. Both test suites must pass before any commit that touches detection,
dictation, or the device payload. Add a regression test with every bug fix.

## Iteration workflow (with Josh)

- After every code change: `pkill -f "debug/tingle"`, rebuild, relaunch
  (`nohup .build/debug/tingle &`). Josh never manages instances himself.
  Only one tingle may run at a time (dev binary OR /Applications/tingle.app).
- Keep a log stream running for live debugging:
  `log stream --predicate 'subsystem == "com.tutorintelligence.tingle"' --info --debug`
  Note: info/debug lines do NOT persist for `log show` — stream to a file.
- Debugging doctrine: Josh's observations of his own hardware are ground
  truth. Instrument and reproduce; never theorize against his report.
  Land the fix with a committed regression test.

## Device payload rules (device/tingle_main.py)

- `device/tingle_main.py` is the source of truth;
  `Sources/TingleCore/Resources/tingle_main.py` must stay byte-identical
  (CI enforces). Sync with `cp` after every edit.
- The device loads `main.py` from its FAT disk at BOOT ONLY (fw 1.0.4):
  every payload change needs Flash EP (menu) + a device power cycle
  (button above the USB-C port, then push the handle).
- NEVER call `fx.load_preset` / `fx.preset*` on a live device while a
  voice is playing — it wedges the audio engine, then the whole device.
- The device has no batteries by default: unplugging USB power-cycles it.
  On batteries it sleeps after 5 min idle (beacons stop — that's sleep,
  not a crash; squeeze the handle to wake).
- Exceptions in the payload callback are swallowed by the crash recorder
  (falls back to stock, writes /fat/tingle_crash.log). Tests must call
  `_tingle_cb` directly to surface errors; check the crash log on-device
  when the engine goes silent.
- Serial REPL access (`/dev/cu.usbmodemEPTXP*`, 115200): `\r\x03\x03`
  grabs the REPL. Never send Ctrl+D (soft reset re-enumerates USB; a
  battery-less unit stays down until the power ritual). tingle holds the
  port exclusively — kill it before REPL diagnostics.

## Hardware facts that bite

- Engine tick rate ~61 Hz. `spl.trigger(-1, slot, False)` cannot stop a
  oneshot sample; sequencing relies on gaps.
- The trigger has TWO sensors: a tactile switch (`ui.sw(4)`, trips ~2%
  travel, huge/sticky release hysteresis) and an analog shaft
  (`ui.handle_raw()`, 0–1). Fast shallow clicks move the switch but not
  the shaft. The payload fuses both (debounce + shaft-trust + stuck-latch).
- The Cubilux HLMS-C4 exposes MIC IN and Line IN input devices; ultrasonic
  chirps bleed across jacks. Device ranking must prefer "line in" names
  and the beacon scanner audits the top-ranked jack before locking.
- Beacons carry handle state on both transports ("EVT beacon 0|1" over
  serial; (1,3)/(3,1) chirp pairs over audio). A LEGACY stateless serial
  beacon line must never be read as "released" (regression: synthesized
  releases killed USB dictation) — healing requires the state token.

## Mac-side invariants

- SpeechTranscriber needs `[.volatileResults, .fastResults]` or output
  arrives in multi-second clumps. Never type inline in the results loop —
  the typing worker converges on the latest hypothesis.
- TranscriptTyper corrections are bounded to the volatile region; any
  external typing during dictation must freezeVolatile() first.
- TCC (mic/accessibility) keys off the code signature: ad-hoc rebuilds of
  the .app re-prompt every time until Developer ID signing lands. The dev
  binary attributes permissions to the invoking terminal instead.

## Release (blocked on Apple Developer enrollment)

Tag `vX.Y.Z` → .github/workflows/release.yml: tests → sign → notarize →
GitHub Release → bump the cask in tutorintelligence/homebrew-tap
(packaging/tingle.rb is the template). Requires the five secrets listed in
the workflow header.
