#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

EXP=172
WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

# Receiver env: print everything, only CFVX saved, overwrite buffer
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$WORKDIR"

ARMED=0
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    "[RX] ident:"*)
      ARMED=1; : > "$WORK"
      echo "[rx-arm] armed; reset $WORK"
      ;;
    "[RX] wrote "*)
      if (( ARMED )) && [ -f "$WORK" ]; then
        echo "[rx-packet] buffer=$(stat -c %s "$WORK") bytes"
      fi
      ;;
    "[RX] completion"*)
      if (( ARMED )) && [ -s "$WORK" ]; then
        cur=$(stat -c %s "$WORK")
        tmp=$(mktemp)
        if [ "$cur" -ge "$EXP" ]; then tail -c "$EXP" "$WORK" > "$tmp"; else cp -f "$WORK" "$tmp"; fi
        mv -f "$tmp" "$PUB"
        chmod 600 "$PUB"
        echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"
      else
        echo "[rx-skip] completion with no data"
      fi
      ARMED=0
      ;;
  esac
done
