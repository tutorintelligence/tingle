# tingle event engine -- copied to the TINGDISK as main.py by FLASH EP.
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
# is on and show live presence -- zero configuration. Open question for
# battery use: whether periodic sample triggers delay the ting's
# power-save (5min) / auto-off (20min) timers; if the unit sleeps, the
# beacon stops and tingle truthfully reports the ting as absent.
#
# Timing facts (fw 1.0.4, measured): type-3 ticks arrive at ~61 Hz
# (16.4ms). spl.trigger(-1, slot, False) does NOT stop a oneshot sample,
# so sequencing relies on gaps, not stops. NEVER call fx.load_preset /
# fx.preset* from here or over the REPL while a voice is playing -- it
# wedges the audio engine.

exec(open('/rom/main.py').read())

# Stock main.py has run: ui/spl/fx are imported, sam_pos/fx_pos are live,
# python_callback is defined and registered.
_stock_cb = python_callback

# Millisecond clock for sleep detection; None when this build has no
# ticks_ms (rotation-only healing then). CPython tests hit the
# AttributeError branch and inject fakes.
try:
    import time
    _tms = time.ticks_ms
    _tdf = time.ticks_diff
except (ImportError, AttributeError):
    _tms = None
    _tdf = None

_t = {'sam': sam_pos, 'fx': fx_pos, 'hdl': ui.sw(4), 'cand': ui.sw(4),
      'cnt': 0, 'q': [], 'gap': 0, 'bcn': 0, 'clk': 0,
      'evq': [], 'heal': [], 'rot': 0, 'hb': 0,
      'lastms': _tms() if _tms else 0,
      # handle-rate tracking for the mash fast-path (hv = last value,
      # rr = consecutive fast-rise ticks)
      'hv': 0.0, 'rr': 0, 'fr': 0}

# Ticks between queued symbol triggers: 2 ticks ~= 29ms at fw 1.0.8's
# ~70Hz -- 25ms symbols with ~4ms gaps (measured clean at 30ms spacing,
# 2026-07-12). One codeword = 4 symbols ~= 110ms on the wire.
_T_SECOND = 2
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
# Slot self-heal: fw <= 1.0.5 reloads FACTORY samples after battery sleep
# (TE changelog 1.0.6: "factory samples are no longer loaded after sleep";
# observed 2026-07-11 on fw 1.0.4 -- audible TE samples on every beacon,
# ultrasound gone, Mac stuck searching). The engine itself survives sleep,
# so it re-arms the slots: a big gap between ticks means we slept or
# stalled -> reload all four tone WAVs (beacon slots 1,3 first, and the
# beacon waits until healing is done); a slow rotation additionally
# re-arms one slot every ~8s against any other clobber path.
_T_HEAL = 488     # rotation period in ticks (~8s; full sweep ~32s)
_WAKE_GAP = 500   # ms without a tick that implies sleep/stall


def _say(*args):
    # NEVER print from the callback: a CDC write can block the whole VM
    # forever if the host vanishes mid-write (USB-C data pins disconnect
    # before power pins, so a vbus guard races -- observed as a full device
    # freeze at unplug, 2026-07-11). Events queue here and are printed
    # only inside q(), which the host calls over the REPL -- output then
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


# RS[4,2] codebook over GF(4) -- min Hamming distance 3 (single-symbol
# error correction on the Mac). MUST match SymbolSet.codebook.
# Message indices: 0 beaconReleased, 1 beaconHeld, 2 triggerDown,
# 3 triggerUp, 4-7 white mode1-4, 8-11 modeChanged 1-4, 12 fxChanged.
_CODE = ((0,0,0,0),(0,1,1,2),(0,2,2,3),(0,3,3,1),
         (1,0,1,1),(1,1,0,3),(1,2,3,2),(1,3,2,0),
         (2,0,2,2),(2,1,3,0),(2,2,0,1),(2,3,1,3),
         (3,0,3,3),(3,1,2,1),(3,2,1,0),(3,3,0,2))


def _word(msg):
    # Queue one codeword (4 symbols); the tick handler plays them
    # _T_SECOND apart. Queuing keeps words serialized -- a button event
    # landing mid-beacon corrupts neither.
    _t['q'] += list(_CODE[msg])


def _reload(s):
    # Re-arm one sample slot from the FAT tone WAV. Signature per the
    # stock /rom/main.py: load_wav(slot, open binary file, playmode) --
    # passing a path string instead of a file object wedges the VM.
    try:
        g = open('/fat/%d.wav' % (s + 1), 'rb')
        spl.load_wav(s, g, 'oneshot')
        g.close()
    except:
        pass


def _tingle_cb(m):
    t = m >> 16
    v = m & 0xFFFF
    # White is NOT chained to stock: its only stock action is playing the
    # slot sample immediately (outside our chirp queue), which used to be
    # the white signal itself -- a lone symbol that could interleave with
    # an in-flight beacon pair and misdecode as green/orange. Instead we
    # queue a same-symbol PAIR (serialized like every other event); the
    # "sample feedback" is ultrasonic anyway, so nothing audible is lost.
    if t == 1 and v == 0:
        _say('EVT white_down', sam_pos, fx_pos)
        _word(4 + sam_pos)
        return
    if t == 2 and v == 0:
        _say('EVT white_up', sam_pos, fx_pos)
        return
    _stock_cb(m)
    if t == 3:
        if _tms:
            _now = _tms()
            if _tdf(_now, _t['lastms']) > _WAKE_GAP:
                # Slept/stalled: firmware may have factory samples loaded.
                # Beacon slots (1,3) first so the heartbeat heals soonest.
                _t['heal'] = [1, 3, 0, 2]
            _t['lastms'] = _now
        _t['hb'] += 1
        if _t['hb'] >= _T_HEAL:
            _t['hb'] = 0
            if not _t['heal']:
                _t['heal'] = [_t['rot']]
                _t['rot'] = (_t['rot'] + 1) % 4
        if sam_pos != _t['sam']:
            _t['sam'] = sam_pos
            _say('EVT mode', sam_pos)
            _word(8 + sam_pos)
        if fx_pos != _t['fx']:
            _t['fx'] = fx_pos
            _say('EVT fx', fx_pos)
            _word(12)
        # Trigger law (measured 2026-07-12): TE's handle() is rate-limited
        # ~0.35/s, so a fast mash finishes physically ~300ms before the
        # signal reaches any deep threshold. Two regimes, cleanly split by
        # RATE:
        #   slow squeeze -> handle tracks the finger; fire at the bottom
        #     (>=0.90), which feels instant because the signal is already
        #     there;
        #   mash -> switch closed while handle still low but climbing
        #     >=0.04/tick for 3 ticks -- a signature that only exists
        #     mid-mash; fires ~45ms after the physical click.
        # Release at <=0.60 either way. All TE signals: switch = when,
        # handle = where, rate = intent.
        hn = ui.handle()
        d = hn - _t['hv']
        _t['rr'] = _t['rr'] + 1 if d >= 0.04 else 0
        # Falling run: release needs the signal to be genuinely DESCENDING,
        # not just low -- a mash's mid-climb stall (one slow tick below
        # 0.60) must not read as a release (observed as instant
        # trigger/untrigger/retrigger, 2026-07-12 00:46).
        _t['fr'] = _t['fr'] + 1 if d <= -0.03 else 0
        _t['hv'] = hn
        mash = _t['rr'] >= 3 and ui.sw(4)
        # Released = below 0.60 while genuinely descending, or fully
        # returned (floor escape so a step-to-zero can't deadlock).
        released = (hn <= 0.60 and _t['fr'] >= 2) or hn <= 0.05
        h = 1 if (hn >= 0.90 or mash) else (0 if released else _t['hdl'])
        if h != _t['cand']:
            _t['cand'] = h
            _t['cnt'] = 0
        elif _t['cnt'] < _T_HDL_DEBOUNCE:
            _t['cnt'] += 1
        if h != _t['hdl'] and _t['cnt'] >= _T_HDL_DEBOUNCE:
            _t['hdl'] = h
            if h:
                _say('EVT trigger_down')
                _word(2)
            else:
                _say('EVT trigger_up')
                _word(3)
        _t['clk'] += 1
        # Beacon heartbeat: fire only when the queue is idle so event
        # chirps always take precedence and sequences never interleave.
        _t['bcn'] += 1
        if _t['bcn'] >= _T_BEACON and not _t['q'] and not _t['heal']:
            _t['bcn'] = 0
            # Audio-only heartbeat; over serial the q() poll's state header
            # carries liveness + handle state instead.
            if _t['hdl']:
                _word(1)
            else:
                _word(0)
        # Play queued tones, evenly spaced.
        if _t['q']:
            if _t['gap'] > 0:
                _t['gap'] -= 1
            else:
                spl.trigger(-1, _t['q'].pop(0), True)
                _t['gap'] = _T_SECOND
        elif _t['heal']:
            if _t['gap'] > 0:
                _t['gap'] -= 1
            else:
                # One slot per tick, and only in chirp silence (gap has
                # fully drained) so a reload never cuts a playing tone.
                _reload(_t['heal'].pop(0))


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
