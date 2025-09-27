#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/cfreceiver"
. .venv/bin/activate 2>/dev/null || { python3 -m venv .venv; . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

SRC="$PWD/data/incoming/vectors.bin"              # app's buffer file
PUB="$HOME/clearframe/data/incoming/vectors.bin"  # published file per loop
EXTRACT="$HOME/cfreceiver/scripts/_extract_last_cfvx.py"

mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# verbose receive; CFVX-only writes; show every UART packet
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"

ARMED=0

# small settle to catch late writes post-completion
settle_after_completion() {
  local prev=-1 cur=0 stable=0
  for _ in $(seq 1 15); do   # ~1.5s at 100ms steps
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1))
      [ "$stable" -ge 3 ] && break
    else
      stable=0
    fi
    prev="$cur"
    sleep 0.1
  done
}

# run the app, merge stderr so we see everything
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"    # clear buffer for new loop
      echo "[rx-arm] ident; reset $SRC"
      ;;

    "[RX] wrote "*)
      (( ARMED )) && echo "[rx-chunk] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
      ;;

    "[RX] completion"*)
      if (( ARMED )); then
        settle_after_completion
        # extract last complete CFVX frame in buffer and publish it
        "$EXTRACT" "$SRC" "$PUB" || echo "[rx-extract] no complete CFVX to publish this loop"
      else
        echo "[rx-note] completion while disarmed; ignored"
      fi
      ARMED=0
      ;;
  esac
done
