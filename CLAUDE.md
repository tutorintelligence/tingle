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
python3 tools/test_next_version.py  # release version-bump logic
scripts/bundle.sh                # assemble dist/tingle.app (ad-hoc unless CODESIGN_IDENTITY set)
swift run tingle                  # run the menu bar app (dev)
```

CI (.github/workflows/ci.yml) runs all of the above plus a payload-sync
check. Both test suites must pass before any commit that touches detection,
dictation, or the device payload. Add a regression test with every bug fix.

## Iteration workflow (with Josh)

- Two blessed run states, switched with one command (Claude runs these;
  Josh never manages instances):
    - `scripts/dev.sh` — dev mode: quits the installed app, builds, runs
      `.build/debug/tingle`. Use during any working session; rerun it
      after every code change.
    - `scripts/dev.sh --stop` — release mode: kills the dev binary and
      reopens /Applications/tingle.app (brew-installed, Sparkle-updated).
      ALWAYS return Josh to release mode at the end of a dev session.
  Only one tingle may run at a time; a flock in App Support enforces it —
  a second launch exits immediately, so switching modes without the
  script silently no-ops.
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
- Firmware update ritual (TE readme, implemented by "Upgrade ting
  firmware…"): lower lid off, USB attached, HOLD the handle the whole
  time, and while holding, DOUBLE-CLICK the small button above the USB
  port -> "TING BOOT" volume appears; drop the .uf2 there. NOT the
  power-ritual button dance.
- Never present NSAlert.runModal() — a modal session parks the main run
  loop and freezes dictation/serial/menu while open. Use FloatingAlert.
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
- fw <= 1.0.5 reloads FACTORY samples after battery sleep (TE fixed in
  1.0.6), silencing the chirp protocol while the engine keeps beaconing —
  audible TE samples every 2s = this. The payload self-heals (tick-gap
  wake detection + slow rotation reload). "Upgrade ting firmware…" in the
  menu flashes TE's pinned-latest UF2 (FirmwareUpgrader.swift: download →
  guided BOOTSEL re-plug → copy .uf2 → re-flash payload); fw 1.0.6+ fixes
  the sleep clobber at the source. The exact fw version is NOT detectable
  (bcdDevice only says 1.00), so the flow flashes unconditionally —
  harmless when already current. Payload-on-1.0.8 still needs one live
  verification.
- spl.load_wav takes (slot, OPEN BINARY FILE, playmode) — passing a path
  string wedges the VM (needs the power ritual). Reference for the whole
  device API: the stock /rom/main.py inside TE's firmware zip.
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
  PermissionsMonitor owns the UX: "!" icon badge, fix-it menu items, launch
  prompts, and a tccutil-reset repair for the stale-Accessibility-row case.

## Contribution flow

main is protected: squash-merge only, PRs required, CI (`test`) must pass.
PR titles must be Conventional Commits (`feat:`, `fix:`, `perf:`,
`refactor:`, `chore:`, `docs:`, `ci:`, `build:`, `test:`, `style:`) with a
lowercase subject — enforced by .github/workflows/pr-title.yml. Since squash
merges use the PR title as the commit subject, that title drives versioning.

Work on a branch, `gh pr create`, let CI + title-lint pass, squash-merge.
Claude cannot push to main directly.

## Release (automated)

.github/workflows/auto-release.yml runs on every push to main: it computes
the next semver from the merge subject via `tools/next_version.py`
(feat→minor, fix/perf/refactor→patch, `!`/BREAKING→major, chore/docs/ci/
build/test/style→no release), then builds → signs+notarizes (if the Apple
secrets exist) → signs the zip with the Sparkle EdDSA key and publishes
appcast.xml to the gh-pages branch (in-app auto-updates; feed URL and
public key live in scripts/bundle.sh's Info.plist; private key is in the
SPARKLE_ED_PRIVATE_KEY repo secret and Josh's login keychain, account
"tingle") → tags → GitHub Release with the .app zip → bumps the cask in
tutorintelligence/homebrew-tap. `tools/test_next_version.py` covers the
version math. Until the Apple Developer secrets land the build is unsigned
but releases still cut. Optional secrets: MACOS_CERT_P12_BASE64,
MACOS_CERT_PASSWORD, NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD,
TAP_DEPLOY_KEY (SSH deploy key that pushes the cask bump to tutorintelligence/homebrew-tap).
