#!/bin/bash
# What Coucou costs while it sits there: its CPU, wakeups and memory, and WindowServer's CPU (the
# process that draws every window, which an app's constant redraws load too).
#   scripts/custom-perf.sh                       measure the Coucou that is running, for 30 s
#   scripts/custom-perf.sh --launch <Coucou.app> [-key '<false/>' ...]
#       quit the running Coucou, open that build with UserDefaults overrides for this launch only
#       (property-list syntax, so a boolean is '<false/>'; nothing is written to the saved
#       settings), wait for it to settle, then measure. Turn a feature off to see what it costs:
#         -buddyEnabled '<false/>'   -runnerEnabled '<false/>'   -voiceEnabled '<false/>'
#         -coucouOpenAtLaunch '<false/>'   (no Coucou window, as at login)
# Readings move with what the island shows (an agent working, background agents breathing the
# aura): compare runs made in the same state, and repeat one when it looks off.
set -euo pipefail

if [ "${1:-}" = "--launch" ]; then
  APP="${2:?usage: custom-perf.sh --launch <Coucou.app> [-key value ...]}"
  shift 2
  pkill -TERM -x Coucou 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x Coucou >/dev/null || break; sleep 0.5; done
  open -n "$APP" --args "$@"
  sleep 35
fi

PID=$(pgrep -x Coucou | head -1 || true)
[ -n "$PID" ] || { echo "Coucou is not running" >&2; exit 1; }

# Six samples of 4 s; the first is top's since-launch figure and is dropped.
top -l 6 -s 4 -n 40 -o cpu -stats pid,command,cpu,idlew 2>/dev/null | awk -v pid="$PID" '
  /^PID/ { block++ }
  block >= 2 && $1 == pid       { c += $3; w += $4; cn++ }
  block >= 2 && $2 == "WindowServer" { s += $3; sn++ }
  END {
    printf "Coucou        %5.1f %% CPU, %5.0f idle wakeups/s\n", cn ? c / cn : 0, cn ? w / cn : 0
    printf "WindowServer  %5.1f %% CPU\n", sn ? s / sn : 0
  }'
echo "Memory        $(footprint "$PID" 2>/dev/null | grep -m1 'Footprint' | sed -E 's/.*Footprint: //')"
