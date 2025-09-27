#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# Paths
SRC="$PWD/data/incoming/vectors.bin"             # where the app writes by default
PUB="$HOME/clearframe/data/incoming/vectors.bin" # published output we care about
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# Expect exactly 172 bytes for this test file
EXP=172

# Receiver verbosity
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1

ARMED=0
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"
      echo "[rx-arm] armed; reset $SRC"
      ;;
    "[RX] wrote "*)
      if (( ARMED )) && [ -f "$SRC" ]; then
        echo "[rx-packet] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
      fi
      ;;
    "[RX] completion"*)
      if (( ARMED )) && [ -s "$SRC" ]; then
        cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
        tmp=$(mktemp)
        if [ "$cur" -ge "$EXP" ]; then
          tail -c "$EXP" "$SRC" > "$tmp"
        else
          cp -f "$SRC" "$tmp"
        fi
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
