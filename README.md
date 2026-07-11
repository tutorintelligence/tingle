# tingle

A tiny macOS menu bar app that turns the [Teenage Engineering EP-2350 "ting"](https://teenage.engineering/store/ep-2350) into a programmable macro button for your Mac.

Press the ting's white button and tingle fires a configurable action — a keystroke, a hotkey, a shell command. The ting's green button selects between 4 sample slots, and each slot can be mapped to a different action, so you get 4 modes out of one button. Built for driving voice-AI workflows (e.g. whisper into the ting, press the button to send), but it's a general-purpose trigger.

## How it works

tingle has two detection backends and uses whichever fits how your ting is connected:

- **USB serial** — when the ting is plugged in over USB-C, tingle talks to its MicroPython REPL and polls button state directly. Zero audio involved. Also surfaces battery level in the menu.
- **Audio tones** — when the ting is wireless (on AAs, plugged into a mixer/line-in), tingle listens on your audio input device. A one-time **FLASH EP** step (in the menu bar dropdown, enabled while the ting is on USB) writes 4 short near-ultrasonic tone samples to the ting's 4 sample slots. Pressing the white button plays the slot's tone through the line-out; tingle detects which tone with a bank of Goertzel filters and fires the mapped action.

## Install

```sh
brew install tutorintelligence/tap/tingle
```

(Not yet published — under development.)

## Configuration

Everything is the literate TOML file at
`~/Library/Application Support/tingle/config.toml` ("Edit config…" in the menu
opens it) — the file documents itself and live-reloads on save. Map any of
`mode1`–`mode4` (white button per green mode), `modeChange` (green),
`fxChange` (orange), or `triggerDown`/`triggerUp` (handle) to actions:

```toml
vocabulary = ["Claude", "Codex"]   # bias dictation toward your names/jargon

[mappings]
triggerDown = { type = "dictate" }                    # live transcription (macOS 26+)
modeChange  = { type = "eraseDictation" }             # erase the last dictated take
fxChange    = { type = "keystroke", key = "return" }
mode1       = { type = "shell", command = """
open -a "Claude"                                      # multiline scripts welcome
""" }
```

Defaults: squeeze the handle to dictate live into the frontmost app, orange =
enter, green = erase the last take (press again for earlier takes).

## Development

```sh
swift run tingle          # dev build, menu bar app
scripts/bundle.sh        # assemble dist/tingle.app (ad-hoc signed)
```

See [DESIGN.md](DESIGN.md) for the architecture, the chirp protocol, and the
hardware findings.

## License

MIT
