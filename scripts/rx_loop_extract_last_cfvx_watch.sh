#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate 2>/dev/null || { python3 -m venv .venv; . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

SRC="$PWD/data/incoming/vectors.bin"              # app buffer
PUB="$HOME/clearframe/data/incoming/vectors.bin"  # published file per loop
EXTRACT="$HOME/cfreceiver/scripts/_extract_last_cfvx.py"
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# Receiver env
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"
# (optional) prefer alias; uncomment if needed:
# export CF_LORA_PORT=/dev/serial0

ARMED=0
WATCHPID=""

start_watch() {
  local prev
  prev=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
  ( 
    p="$prev"
    while :; do
      cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
      if [ "$cur" != "$p" ]; then
        echo "[rx-chunk] buffer=${cur} bytes"
        p="$cur"
      fi
      sleep 0.10
    done
  ) & WATCHPID=$!
}

stop_watch() { [ -n "${WATCHPID:-}" ] && kill "$WATCHPID" 2>/dev/null || true; WATCHPID=""; }

settle_after_completion() {
  local prev=-1 cur=0 stable=0
  for _ in $(seq 1 15); do   # ~1.5s max, exit early when stable
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1)); [ "$stable" -ge 3 ] && break
    else
      stable=0
    fi
    prev="$cur"; sleep 0.10
  done
}

stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"
      echo "[rx-arm] ident; reset $SRC"
      stop_watch; start_watch
      ;;
    "[RX] completion"*)
      if (( ARMED )); then
        settle_after_completion
        stop_watch
        "$EXTRACT" "$SRC" "$PUB" || echo "[rx-extract] no complete CFVX to publish this loop"
      else
        echo "[rx-note] completion while disarmed; ignored"
      fi
      ARMED=0
      ;;
  esac
done
