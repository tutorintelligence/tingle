#!/usr/bin/env python3
"""Unit tests for the on-device event engine (device/tingle_main.py).

Runs the payload against stubbed firmware modules and drives the callback
directly (bypassing the crash recorder, which by design SWALLOWS
exceptions — tests must call _tingle_cb to surface them).

Run: python3 tools/test_payload.py
"""
import unittest
from pathlib import Path

PAYLOAD = Path(__file__).resolve().parent.parent / "device" / "tingle_main.py"
TICK = 3 << 16
WHITE_DOWN = 1 << 16
WHITE_UP = 2 << 16


class FakeUI:
    def __init__(self):
        self.sw4 = 0          # legacy switch (no longer drives the trigger)
        self.raw = 0.0        # legacy raw shaft
        self.hdl = 0.0        # TE's processed handle position 0..1 (drives the trigger)
        self.vbus = 1
        self.said = []        # captured via fake print in namespace

    def sw(self, i):
        return self.sw4 if i == 4 else 1

    def handle(self):
        return self.hdl

    def handle_raw(self):
        return self.raw

    def get_vbus(self):
        return self.vbus

    def __getattr__(self, name):
        return lambda *a, **k: 0


class FakeSPL:
    def __init__(self):
        self.triggers = []
        self.loads = []   # (slot, playmode) from load_wav

    def trigger(self, chan, slot, on):
        self.triggers.append(slot)
        return True

    def load_wav(self, slot, f, playmode):
        self.loads.append((slot, playmode))
        return True

    def __getattr__(self, name):
        return lambda *a, **k: 0


class FakeFile:
    def read(self, *a):
        return b""

    def close(self):
        pass


class Stub:
    def __getattr__(self, name):
        return lambda *a, **k: 0


def boot(sw4=0):
    """Load the payload with stubs; returns (namespace, ui, spl, said)."""
    src = PAYLOAD.read_text().replace("exec(open('/rom/main.py').read())", "pass")
    ui, spl = FakeUI(), FakeSPL()
    ui.sw4 = sw4
    said = []
    ns = {
        "ui": ui, "spl": spl, "fx": Stub(),
        "sam_pos": 0, "fx_pos": -1,
        "python_callback": lambda m: None,
        "print": lambda *a: said.append(" ".join(str(x) for x in a)),
        "open": lambda *a, **k: FakeFile(),
    }
    exec(compile(src, "tingle_main.py", "exec"), ns)
    return ns, ui, spl, said


def ticks(ns, n):
    for _ in range(n):
        ns["_tingle_cb"](TICK)


def install_clock(ns, start=1000):
    """CPython has no time.ticks_ms, so the payload boots with wake
    detection off; tests inject a controllable millisecond clock."""
    clock = [start]
    ns["_tms"] = lambda: clock[0]
    ns["_tdf"] = lambda a, b: a - b
    ns["_t"]["lastms"] = start
    return clock


class PayloadTests(unittest.TestCase):
    def test_boot_and_first_ticks_do_not_crash(self):
        # Regression: _t['cand'] was uninitialized -> KeyError on tick 1.
        ns, *_ = boot()
        ticks(ns, 5)

    def test_long_idle_only_beacons(self):
        ns, ui, spl, said = boot()
        ticks(ns, 140)  # > one beacon period + queue drain (tones 8 ticks apart)
        ns["q"]()
        self.assertTrue(said[0].startswith("S "), "state header on poll")
        # released-state beacon = chirp (1, 3)
        self.assertEqual(spl.triggers[:4], [0, 0, 0, 0])  # beaconReleased codeword

    def test_beacon_encodes_held_state(self):
        ns, ui, spl, said = boot()
        ui.hdl = 0.95
        ticks(ns, 25)   # debounce + edge + full chirp queue drain
        spl.triggers.clear()
        ticks(ns, 140)
        self.assertEqual(spl.triggers[:4], [0, 1, 1, 2], "held beacon = codeword 1")

    def test_trigger_edges_debounced_and_chirped(self):
        ns, ui, spl, said = boot()
        ui.hdl = 0.95
        ticks(ns, 10)
        ns["q"]()
        self.assertIn("EVT trigger_down", said)
        self.assertEqual(spl.triggers[:1], [0])   # chirp (0,2) begins
        ui.hdl = 0.0
        ticks(ns, 10)
        ns["q"]()
        self.assertIn("EVT trigger_up", said)

    def test_full_hold_never_releases_early(self):
        # Regression (2026-07-11): fw 1.0.8 reads handle_raw ~0.01 even
        # fully depressed; the old shaft-trust heuristic force-released
        # every real hold (~trips at 0.006-0.019). Switch-only now: a
        # closed switch with a zero shaft must stay HELD indefinitely.
        ns, ui, spl, said = boot()
        ui.hdl = 0.95   # full squeeze on TE's processed signal
        ticks(ns, 610)             # ~10s hold
        ns["q"]()
        downs = sum("trigger_down" in x for x in said)
        ups = sum("trigger_up" in x for x in said)
        self.assertEqual(downs, 1, "one press")
        self.assertEqual(ups, 0, "no phantom release during a 10s hold")
        ui.hdl = 0.0
        ticks(ns, 10)
        ns["q"]()
        self.assertTrue(any("trigger_up" in x for x in said), "release on switch open")

    def test_mash_fires_fast_via_rate_path(self):
        # Measured: handle() slews ~0.05/tick on a mash while the switch
        # is already closed. The rate path must fire within ~7 ticks
        # instead of waiting ~19 ticks for the 0.90 threshold.
        ns, ui, spl, said = boot()
        ui.sw4 = 1
        fired_at = None
        for i in range(30):
            ui.hdl = min(0.99, 0.05 * i)
            ns["_tingle_cb"](TICK)
            ns["q"]()
            if fired_at is None and any("trigger_down" in x for x in ui.said + said):
                fired_at = i
        self.assertIsNotNone(fired_at, "mash fires")
        self.assertLess(fired_at, 9, f"rate path fires fast (tick {fired_at})")

    def test_mash_climb_stall_does_not_release(self):
        # Regression (00:46): one slow tick mid-climb (delta < 0.04 while
        # handle < 0.60) dropped the mash flag and the low handle read as
        # a release -> instant untrigger/retrigger. Release now requires
        # a genuine FALLING run.
        ns, ui, spl, said = boot()
        ui.sw4 = 1
        profile = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35,
                   0.36, 0.36,                     # the stall
                   0.41, 0.46, 0.51, 0.56, 0.61, 0.66, 0.71,
                   0.76, 0.81, 0.86, 0.91, 0.95, 0.95, 0.95]
        for v in profile:
            ui.hdl = v
            ns["_tingle_cb"](TICK)
        ns["q"]()
        downs = sum("trigger_down" in x for x in said)
        ups = sum("trigger_up" in x for x in said)
        self.assertEqual(downs, 1, "one press through the stall")
        self.assertEqual(ups, 0, "stall never reads as release")
        # real release still fast
        for v in [0.9, 0.84, 0.78, 0.72, 0.66, 0.60, 0.54, 0.48, 0.4, 0.3, 0.2, 0.1, 0.0, 0.0]:
            ui.hdl = v
            ns["_tingle_cb"](TICK)
        ns["q"]()
        self.assertTrue(any("trigger_up" in x for x in said), "real release fires")

    def test_slow_rest_at_top_never_fires(self):
        # Switch closes at ~0% travel; resting there (low handle, no
        # rate) must NOT trigger.
        ns, ui, spl, said = boot()
        ui.sw4 = 1
        ui.hdl = 0.10
        ticks(ns, 200)
        ns["q"]()
        self.assertFalse(any("trigger_down" in x for x in said), "no fire at rest")

    def test_bounce_storm_emits_no_edges(self):
        ns, ui, spl, said = boot()
        # Alternate the switch every tick: never stable for the debounce.
        for i in range(20):
            ui.sw4 = i % 2
            ns["_tingle_cb"](TICK)
        self.assertNotIn("EVT trigger_down", said)
        self.assertNotIn("EVT trigger_up", said)

    def test_white_press_queues_same_symbol_pair(self):
        # White is a queued SAME-SYMBOL pair (serialized with beacons);
        # stock is deliberately not chained for white (its only stock
        # action was unserialized sample playback = the old collision-
        # prone lone symbol).
        ns, ui, spl, said = boot()
        ns["_tingle_cb"](WHITE_DOWN)
        self.assertEqual(ns["_t"]["q"], [1, 0, 1, 1], "white in mode 1 queues codeword 4")
        ticks(ns, 20)
        self.assertEqual(spl.triggers[:4], [1, 0, 1, 1], "word plays serialized")

    def test_white_press_events(self):
        ns, ui, spl, said = boot()
        ns["_tingle_cb"](WHITE_DOWN)
        ns["_tingle_cb"](WHITE_UP)
        ns["q"]()
        self.assertIn("EVT white_down 0 -1", said)
        self.assertIn("EVT white_up 0 -1", said)

    def test_crash_recorder_swallows_and_falls_back(self):
        ns, ui, spl, said = boot()
        ns["_tingle_cb"] = lambda m: 1 / 0
        ns["python_callback"](TICK)   # must not raise

    def test_callback_never_prints(self):
        """The USB-unplug freeze fix: a CDC write can block the VM forever
        if the host dies mid-write, so the callback must NEVER print --
        events queue and only q() (host-invoked) prints."""
        ns, ui, spl, said = boot()
        ui.vbus = 1
        ticks(ns, 140)                       # beacons
        ns["_tingle_cb"](WHITE_DOWN)         # events
        ns["_tingle_cb"](WHITE_UP)
        ui.hdl = 0.95
        ticks(ns, 10)                        # trigger edge
        self.assertEqual(said, [], "callback printed! wedge risk reintroduced")

    def test_q_drains_queue_with_state_header(self):
        ns, ui, spl, said = boot()
        ns["_tingle_cb"](WHITE_DOWN)
        ns["_tingle_cb"](WHITE_UP)
        ns["q"]()
        self.assertTrue(said[0].startswith("S 0 0 -1"), f"state header first: {said[:1]}")
        self.assertIn("EVT white_down 0 -1", said)
        self.assertIn("EVT white_up 0 -1", said)
        said.clear()
        ns["q"]()
        self.assertEqual(len(said), 1, "queue drained; only the header repeats")

    def test_q_header_reflects_held_state(self):
        ns, ui, spl, said = boot()
        ui.hdl = 0.95
        ticks(ns, 10)
        said.clear()
        ns["q"]()
        self.assertTrue(said[0].startswith("S 1 "), f"held in header: {said[0]}")

    def test_event_queue_bounded(self):
        ns, ui, spl, said = boot()
        for _ in range(200):
            ns["_tingle_cb"](WHITE_DOWN)
            ns["_tingle_cb"](WHITE_UP)
        ns["q"]()
        self.assertLessEqual(len(said), 66, "queue must be bounded")



class SlotSelfHealTests(unittest.TestCase):
    """Regression for the 2026-07-11 incident: fw 1.0.4 reloads FACTORY
    samples after battery sleep, silencing the chirp protocol. The engine
    must re-arm its tone WAVs after any tick gap and via slow rotation."""

    def test_wake_gap_reloads_all_slots_beacons_first(self):
        ns, ui, spl, said = boot()
        clock = install_clock(ns)
        for _ in range(5):
            clock[0] += 16
            ticks(ns, 1)
        self.assertEqual(spl.loads, [], "no healing during normal ticking")
        clock[0] += 300000   # 5 min asleep
        ticks(ns, 4)
        self.assertEqual([s for s, _ in spl.loads], [1, 3, 0, 2],
                         "all four slots reload, beacon slots first")
        self.assertTrue(all(pm == "oneshot" for _, pm in spl.loads))

    def test_beacon_waits_until_heal_done(self):
        ns, ui, spl, said = boot()
        clock = install_clock(ns)
        ns["_t"]["bcn"] = 121   # beacon due on the next tick
        clock[0] += 300000
        ticks(ns, 1)            # wake detected; heal starts
        self.assertEqual(spl.triggers, [], "beacon deferred while healing")
        ticks(ns, 5)
        self.assertEqual(len(spl.loads), 4)
        ticks(ns, 130)          # beacon period passes after heal
        self.assertEqual(spl.triggers[:4], [0, 0, 0, 0], "beacon resumes after heal")

    def test_rotation_heals_one_slot_every_period(self):
        # Default CPython boot: _tms is None (no wake detection) — the
        # rotation path must still re-arm slots.
        ns, ui, spl, said = boot()
        self.assertIsNone(ns["_tms"])
        # Period is 488 ticks plus the beacon-tone gap drain (~10 ticks).
        ticks(ns, 510)
        self.assertEqual([s for s, _ in spl.loads], [0])
        ticks(ns, 510)
        self.assertEqual([s for s, _ in spl.loads], [0, 1])

    def test_reload_never_interrupts_chirps(self):
        ns, ui, spl, said = boot()
        clock = install_clock(ns)
        clock[0] += 300000
        ui.hdl = 0.95   # squeeze at the same time as wake
        ticks(ns, 1)
        # Trigger chirp is queued; reloads must wait for the queue AND the
        # post-tone gap to drain before touching any slot.
        for _ in range(60):
            busy = bool(ns["_t"]["q"]) or ns["_t"]["gap"] > 0
            before = len(spl.loads)
            ticks(ns, 1)
            if busy:
                self.assertEqual(len(spl.loads), before,
                                 "no reload while tones queued or sounding")
        self.assertEqual(len(spl.loads), 4, "healing completes afterwards")

if __name__ == "__main__":
    unittest.main(verbosity=1)
