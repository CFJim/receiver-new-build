#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# Paths: follow the app's default write target inside the repo
SRC="$PWD/data/incoming/vectors.bin"
PUB="$HOME/clearframe/data/incoming/vectors.bin"
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# This test expects 172 bytes exactly
EXP=172

# Receiver verbosity + CFVX-only writes
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1

ARMED=0
SAW_DATA=0

# Merge stderr so we see sniffer + all logs
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | \
while IFS= read -r line; do
  echo "$line"

  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      SAW_DATA=0
      : > "$SRC"
      echo "[rx-arm] armed; reset $SRC"
      ;;

    "[RX] wrote "*)
      # App only writes when CFVX matched, so this implies data
      if (( ARMED )); then
        SAW_DATA=1
        [ -f "$SRC" ] && echo "[rx-packet] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
      fi
      ;;

    "[RX] completion"*)
      if (( ARMED )) && (( SAW_DATA )) && [ -s "$SRC" ]; then
        cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
        tmp=$(mktemp)
        if [ "$cur" -ge "$EXP" ]; then
          tail -c "$EXP" "$SRC" > "$tmp"
        else
          cp -f "$SRC" "$tmp"
        fi
        install -m 600 "$tmp" "$PUB"
        rm -f "$tmp"
        echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"
        ARMED=0
        SAW_DATA=0
      else
        # Ignore completions from LEN/SHA, keep waiting for data
        echo "[rx-skip] completion pre-data; staying armed"
      fi
      ;;
  esac
done
