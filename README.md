# tingle

Voice-first agentic coding with a [Teenage Engineering EP-2350 "ting"](https://teenage.engineering/store/ep-2350).

Squeeze the ting's trigger and talk — tingle transcribes live into whatever
app is focused (Claude Code, Codex, anything). Release to finish, tap orange
to send, tap green to scrap the take. Button presses reach your Mac over USB
serial when docked, or over an inaudible ultrasonic chirp protocol when the
ting runs wireless on batteries into a line-in. A tiny MicroPython event
engine, installed onto the ting's own disk with one click (no firmware
modification, fully reversible), makes all of it work.

## Hardware setup

You need:

1. **A Teenage Engineering EP-2350 "ting"** — the lo-fi FX microphone.
2. **A USB line-in adapter.** The ting's curly cable outputs *line-level*
   audio, and Mac headphone jacks don't accept line-in — plugging the ting
   straight into your laptop's 3.5mm port will not work. Any USB audio
   interface with a line input is fine; a cheap one that works well is the
   [Cubilux USB-C line-in adapter](https://www.amazon.com/dp/B0CNCL21RR)
   (line-in + mic-in + headphone-out on one USB-C plug).
3. Optionally, **a USB-C cable** to the ting for docked use (instant button
   events, battery readout) and for the one-time flash.

Wiring: ting line-out → adapter **line-in** port → Mac USB. Turn the green
volume knob under the ting's lid up to around halfway.

## Getting started

```sh
brew install tutorintelligence/tap/tingle   # (not yet published)
```

1. Launch tingle — a striped-circle icon appears in the menu bar.
2. Plug the ting in over USB-C and choose **Flash EP…** from the menu. This
   writes four inaudible signal tones and the event engine onto the ting's
   disk (existing contents are backed up first). Power-cycle the ting when
   prompted: press the small button above its USB-C port, then push the
   handle to start it.
3. Grant the two permission prompts (microphone, accessibility).
4. Squeeze the trigger and talk. Words appear where your cursor is.

The menu bar dot tells you everything: green = ting present (USB, or heard
by its ultrasonic heartbeat), orange = searching, red = trigger held /
dictating, none = no ting around. Input-device selection is automatic —
tingle finds whichever line-in the ting is plugged into by listening for
its heartbeat.

## Default controls

| Input | Action |
|---|---|
| squeeze handle | dictate live into the focused app; release to finish |
| orange button | enter (send it) |
| green button | erase the last dictated take (repeat for earlier takes) |
| white button | summon your agent — brings the first running AI coding app (Claude, Codex, Cursor, iTerm2, Terminal) to the front |

Every one of these is just a default. tingle is configurable by design: the
whole control scheme lives in the TOML file below, and any behavior — the
summon list, what green erases, what orange sends, the dictation vocabulary —
is yours to change.

## Configuration

Everything lives in one literate TOML file —
`~/Library/Application Support/tingle/config.toml` ("Edit config…" in the
menu) — which documents itself and live-reloads on save:

```toml
vocabulary = ["Claude", "Codex", "kubectl"]   # bias recognition toward your jargon

[replacements]                                # fix what biasing can't
"Tamil" = "TOML"

[mappings]
triggerDown = { type = "dictate" }
fxChange    = { type = "keystroke", key = "return" }
modeChange  = { type = "eraseDictation" }
mode1       = { type = "shell", command = """
open -a "Claude"                              # multiline scripts welcome
""" }
```

Actions: `dictate`, `eraseDictation`, `keystroke`, `keyHold` (held until you
release the trigger), and `shell`. The white button gives you four mappable
slots (`mode1`–`mode4`), selected by the ting's green mode LED.

Dictation uses Apple's on-device speech stack (macOS 26+). Everything else
works on macOS 13+.

## How it works

The ting executes user Python from its USB disk at boot. tingle ships an
event engine that chains the stock firmware behavior, then reports button
and trigger events as serial lines (docked) and as two-tone ultrasonic
chirps at 17.5–19 kHz (wireless) — decoded on the Mac by a Goertzel filter
bank. A state-carrying heartbeat every 2 seconds powers zero-config device
discovery and self-healing state sync. Details, protocol table, and the
measured hardware reference: [DESIGN.md](DESIGN.md).

## Development

```sh
swift run tingle                # run the menu bar app (dev build)
swift run tingle-tests          # unit tests
python3 tools/test_payload.py   # device event-engine tests
scripts/bundle.sh               # assemble dist/tingle.app
```

Agent-oriented contributor docs: [CLAUDE.md](CLAUDE.md) (symlinked as
AGENTS.md).

## License

MIT © Tutor Intelligence
