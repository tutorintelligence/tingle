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

osascript -e 'tell application "tingle" to quit' 2>/dev/null || true
pkill -f "debug/tingle" 2>/dev/null || true
swift build
sleep 0.5
nohup .build/debug/tingle >/dev/null 2>&1 &
sleep 1
echo "dev mode: .build/debug/tingle running ($(git rev-parse --short HEAD))"
