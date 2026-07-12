#!/bin/zsh
# Dev/release mode switch. Only one tingle can run (flock-enforced), so
# these are the two blessed states:
#
#   scripts/dev.sh          dev mode: quit the installed app, build, run
#                           the dev binary from .build/debug
#   scripts/dev.sh --stop   release mode: kill the dev binary, reopen
#                           /Applications/tingle.app (brew-installed)
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--stop" ]]; then
    pkill -f "debug/tingle" 2>/dev/null || true
    sleep 0.5
    if [[ -d /Applications/tingle.app ]]; then
        open /Applications/tingle.app
        echo "release mode: /Applications/tingle.app running"
    else
        echo "release mode: no installed app found (brew install it first)"
    fi
    exit 0
fi

# Graceful quit, but NEVER trust it: a wedged production app (e.g. the
# AVAudioEngine config-change deadlock) ignores Apple events, and the
# flock would then silently kill the dev binary instead.
osascript -e 'tell application "tingle" to quit' 2>/dev/null || true
pkill -f "debug/tingle" 2>/dev/null || true
for i in $(seq 1 6); do
    pgrep -f "/Applications/tingle.app" >/dev/null 2>&1 || break
    sleep 0.5
    [[ $i -eq 6 ]] && pkill -9 -f "/Applications/tingle.app"
done
sleep 0.5
if pgrep -x tingle >/dev/null 2>&1; then
    echo "ERROR: a tingle instance refuses to die; aborting" >&2
    exit 1
fi
swift build
nohup .build/debug/tingle >/dev/null 2>&1 &
sleep 1.5
if pgrep -f "debug/tingle" >/dev/null 2>&1; then
    echo "dev mode: .build/debug/tingle running ($(git rev-parse --short HEAD))"
else
    echo "ERROR: dev binary exited immediately (flock? crash?) — check logs" >&2
    exit 1
fi
