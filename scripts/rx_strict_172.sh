#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }
mkdir -p "$HOME/clearframe/data/incoming" "data/incoming"

# Verbose + binary save path; accept our cube header; show UART reads if supported
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_SERIAL_SNIFFER=1
export CF_RX_OVERWRITE=1

# Working file (repo-relative) and single public file
WORK="data/incoming/vectors.bin"
PUB="$HOME/clearframe/data/incoming/vectors.bin"

# start fresh
: > "$WORK"

stdbuf -oL -eL python app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # On ID: truncate so this loop starts clean
  if [[ "$line" == "[RX] ident:"* ]]; then
    : > "$WORK"
  fi

  # On completion + write: clip to exactly 172 bytes and publish single file
  if [[ "$line" == "[RX] wrote data/incoming/vectors.bin ("* || "$line" == "[RX] completion"* ]]; then
    if [ -f "$WORK" ]; then
      sz=$(stat -c %s "$WORK" 2>/dev/null || echo 0)
      if [ "$sz" -ne 172 ]; then
        tmp=$(mktemp)
        # keep only the last 172 bytes from the working file
        tail -c 172 "$WORK" > "$tmp" || : > "$tmp"
        mv -f "$tmp" "$WORK"
      fi
      cp -f "$WORK" "$PUB"
      echo "[rx-strict] wrote $PUB ($(stat -c %s "$PUB") bytes)"
    fi
  fi
done
