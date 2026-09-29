#!/usr/bin/env bash
# Drive a caption worker to completion: restart on exit 75 ("more work remains"),
# retry after 60s on any other failure, stop on 0. Each restart gets a fresh MPS pool and
# resumes from existing .vtt files plus any per-window checkpoint.
#
#   scripts/transcribe/run_until_done.sh caption_zh.py ~/Podcasts/some-show
set -uo pipefail
cd "$(dirname "$0")"
PY=${PY:-../../venv/bin/python}
LOG_DIR=/tmp/ear-to-listen-transcribe
mkdir -p "$LOG_DIR"
RUNLOG="$LOG_DIR/run.log"
script=$1; shift

say() { echo "$(date '+%F %T') $*" | tee -a "$RUNLOG"; }

say "=== starting: $script $* (tail -f $RUNLOG) ==="
caffeinate -is -w $$ &
pass=0
while true; do
    pass=$((pass + 1))
    "$PY" "$script" "$@" >>"$RUNLOG" 2>&1
    rc=$?
    case $rc in
        0)  say "=== complete after $pass passes ==="; exit 0 ;;
        75) : ;;
        *)  say "=== worker exited $rc on pass $pass; retrying in 60s ==="; sleep 60 ;;
    esac
done
