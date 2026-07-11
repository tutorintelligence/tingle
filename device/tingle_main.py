# tingle event engine — copied to the TINGDISK as main.py by FLASH EP.
# The ting executes /fat/main.py at boot (verified fw 1.0.4). Delete this
# file from the disk to restore 100% stock behavior.
#
# Runs the stock program first (all TE behavior preserved), then wraps its
# event callback to:
#   - print "EVT ..." lines over USB CDC serial (consumed by tingle's serial
#     backend when docked; vbus-guarded and discarded when on batteries)
#   - play two-tone chirps through the line-out so tingle's audio backend
#     can detect events over the 3.5mm cable. Tones 1-4 = slots 0-3
#     (80ms, 17.5/18/18.5/19 kHz):
#       single tone N              -> white press in mode N (stock playback)
#       tone N then tone (N+1)%4   -> mode changed to N (green)
#       tone N then tone (N-1)%4   -> fx preset changed, current mode N
#       tone 0 then tone 2 (fixed) -> handle squeezed (mic went live)
#       tone 2 then tone 0 (fixed) -> handle released (mic off)
#       tone 1 then tone 3 (fixed) -> beacon heartbeat, handle RELEASED
#       tone 3 then tone 1 (fixed) -> beacon heartbeat, handle HELD
#     The beacon carries handle state so a lost trigger chirp self-heals
#     within one beacon period (the Mac synthesizes the missed edge).
#     The fixed pairs (+2 apart) can never be produced by the relative
#     mode/fx encodings, so decoding stays collision-free.
#
# The beacon lets tingle auto-discover which audio input device the ting
# is on and show live presence — zero configuration. Open question for
# battery use: whether periodic sample triggers delay the ting's
# power-save (5min) / auto-off (20min) timers; if the unit sleeps, the
# beacon stops and tingle truthfully reports the ting as absent.
#
# Timing facts (fw 1.0.4, measured): type-3 ticks arrive at ~61 Hz
# (16.4ms). spl.trigger(-1, slot, False) does NOT stop a oneshot sample,
# so sequencing relies on gaps, not stops. NEVER call fx.load_preset /
# fx.preset* from here or over the REPL while a voice is playing — it
# wedges the audio engine.

exec(open('/rom/main.py').read())

# Stock main.py has run: ui/spl/fx are imported, sam_pos/fx_pos are live,
# python_callback is defined and registered.
_stock_cb = python_callback
_t = {'sam': sam_pos, 'fx': fx_pos, 'hdl': ui.sw(4), 'cand': ui.sw(4),
      'cnt': 0, 'stk': 0, 'q': [], 'gap': 0, 'bcn': 0, 'clk': 0,
      'evq': []}

# Ticks between queued tone triggers (~130ms @ 61Hz), leaving a ~50ms gap
# after each 80ms sample — tightened for wireless event latency.
_T_SECOND = 8
# Trigger from the switch (ui.sw(4)) with edge debounce: the switch
# bounces mechanically (rapid down/up over a tick or two), and raw
# per-tick sampling turns that bounce into an event storm that wedges the
# host. Require the new state to persist _T_HDL_DEBOUNCE ticks before
# emitting the edge. (The triple-click gesture that needed no debounce was
# abandoned, so this is free.)
_T_HDL_DEBOUNCE = 3   # ~50ms; longer than bounce, shorter than any real press
# Beacon period in ticks (~2s @ 61Hz). ~320ms of tone activity per
# period = 16% line duty; fast enough for ~5s auto-discovery and ~6s
# loss detection without meaningfully delaying event chirps.
_T_BEACON = 122


def _say(*args):
    # NEVER print from the callback: a CDC write can block the whole VM
    # forever if the host vanishes mid-write (USB-C data pins disconnect
    # before power pins, so a vbus guard races — observed as a full device
    # freeze at unplug, 2026-07-11). Events queue here and are printed
    # only inside q(), which the host calls over the REPL — output then
    # happens microseconds after proven-live host bytes.
    _t['evq'].append(' '.join(str(a) for a in args))
    if len(_t['evq']) > 64:
        _t['evq'].pop(0)


def q():
    # Host poll (the Mac sends "q()\r" every ~150ms). One state header --
    # trigger/mode/fx/battery -- then any queued events. Printing here is
    # safe by construction: the host just wrote to us.
    print('S', 1 if _t['hdl'] else 0, sam_pos, fx_pos, ui.get_vbat())
    for _line in _t['evq']:
        print(_line)
    _t['evq'] = []


def _chirp(first_slot, second_slot):
    # Queue both tones; the tick handler plays queued tones _T_SECOND
    # apart. Queuing (vs. clobbering a single pending slot) means a button
    # event landing mid-beacon corrupts neither signal.
    _t['q'] += [first_slot, second_slot]


def _tingle_cb(m):
    _stock_cb(m)
    t = m >> 16
    v = m & 0xFFFF
    if t == 1 and v == 0:
        _say('EVT white_down', sam_pos, fx_pos)
    elif t == 2 and v == 0:
        _say('EVT white_up', sam_pos, fx_pos)
    elif t == 3:
        if sam_pos != _t['sam']:
            _t['sam'] = sam_pos
            _say('EVT mode', sam_pos)
            _chirp(sam_pos, (sam_pos + 1) % 4)
        if fx_pos != _t['fx']:
            _t['fx'] = fx_pos
            _say('EVT fx', fx_pos)
            _chirp(sam_pos, (sam_pos + 3) % 4)
        h = ui.sw(4)
        if not h:
            _t['stk'] = 0   # switch opened: stuck-latch clears
        elif _t['stk']:
            h = 0           # latched: a stuck switch cannot re-press
        elif _t['hdl'] and ui.handle_raw() < 0.05:
            # Switch claims held but the shaft is fully returned: the
            # switch's release threshold sticks (~40-60% travel) or the
            # element hangs electrically. Trust the shaft — and LATCH:
            # without the latch, ADC noise around the threshold flaps
            # held/released at ~1Hz until the shaft settles (observed
            # 2026-07-11 16:36 as a green/red strobing icon).
            h = 0
            _t['stk'] = 1
        # Debounce: only accept a state that holds steady for N ticks.
        if h != _t['cand']:
            _t['cand'] = h
            _t['cnt'] = 0
        elif _t['cnt'] < _T_HDL_DEBOUNCE:
            _t['cnt'] += 1
        if h != _t['hdl'] and _t['cnt'] >= _T_HDL_DEBOUNCE:
            _t['hdl'] = h
            if h:
                _say('EVT trigger_down')
                _chirp(0, 2)
            else:
                _say('EVT trigger_up')
                _chirp(2, 0)
        _t['clk'] += 1
        # Beacon heartbeat: fire only when the queue is idle so event
        # chirps always take precedence and sequences never interleave.
        _t['bcn'] += 1
        if _t['bcn'] >= _T_BEACON and not _t['q']:
            _t['bcn'] = 0
            # Audio-only heartbeat; over serial the q() poll's state header
            # carries liveness + handle state instead.
            if _t['hdl']:
                _chirp(3, 1)
            else:
                _chirp(1, 3)
        # Play queued tones, evenly spaced.
        if _t['q']:
            if _t['gap'] > 0:
                _t['gap'] -= 1
            else:
                spl.trigger(-1, _t['q'].pop(0), True)
                _t['gap'] = _T_SECOND


def python_callback(m):
    # Last-gasp crash recorder: if the tingle engine ever throws, dump the
    # traceback to the disk and fall back to the stock callback so the
    # device keeps working instead of wedging (and we get evidence).
    try:
        _tingle_cb(m)
    except Exception as e:
        try:
            ui.callback(_stock_cb)
        except:
            pass
        try:
            import sys
            f = open('/fat/tingle_crash.log', 'a')
            f.write('tick %d msg %x\n' % (_t.get('clk', -1), m))
            sys.print_exception(e, f)
            f.close()
        except:
            pass


ui.callback(python_callback)
