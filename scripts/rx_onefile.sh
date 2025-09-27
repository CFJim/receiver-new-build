#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }
mkdir -p "$HOME/clearframe/data/incoming" "data/incoming"

# Verbose + binary save; accept our CFXV header; show UART reads if supported
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_SAVE_DIR="$HOME/clearframe/data/incoming"
export CF_RX_OVERWRITE=1
export CF_SERIAL_SNIFFER=1

# Start clean
: > data/incoming/vectors.bin

# Run the app; when we see a new ident, truncate before receiving the data.
# When we see a write, print the exact size and warn if not 172 bytes.
stdbuf -oL -eL python app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"
  if [[ "$line" == "[RX] ident:"* ]]; then
    : > data/incoming/vectors.bin
  fi
  if [[ "$line" == "[RX] wrote data/incoming/vectors.bin ("* ]]; then
    sz=$(stat -c %s data/incoming/vectors.bin 2>/dev/null || echo 0)
    echo "[rx-verify] size=${sz} bytes (expected 172)"
  fi
done
