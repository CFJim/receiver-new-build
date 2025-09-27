#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORK="data/incoming/vectors.bin"
PUB="$HOME/clearframe/data/incoming/vectors.bin"
mkdir -p "$(dirname "$WORK")" "$(dirname "$PUB")"
: > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1   # print every UART chunk (hex) so LEN/SHA are visible
export CF_RX_ASCII=0         # keep binary receive path
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01  # only CFVX payloads get written by the app
export CF_RX_OVERWRITE=1

# Helper: compute expected CFVX length from header
cfvx_expected_len () {
  python3 - "$1" <<'PY'
import sys, struct, os
p=sys.argv[1]
try:
  if os.path.getsize(p) < 28: print(0); sys.exit()
  with open(p,'rb') as f:
    if f.read(6)!=b'CFVX01': print(0); sys.exit()
    f.read(1); f.read(16); f.read(1)
    vcnt, ecnt = struct.unpack('<HH', f.read(4))
    print(28 + vcnt*12 + ecnt*4)
except Exception: print(0)
PY
}

stdbuf -oL -eL python app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # Start a clean buffer on each new ident (beginning of a send)
  if [[ "$line" == "[RX] ident:"* ]]; then
    : > "$WORK"
  fi

  # When the app writes the CFVX file (only for CFVX sends), clamp and publish
  if [[ "$line" == "[RX] wrote data/incoming/vectors.bin ("* || "$line" == "[RX] completion"* ]]; then
    if [ -f "$WORK" ] && [ -s "$WORK" ]; then
      exp=$(cfvx_expected_len "$WORK" || echo 0)
      if [ "$exp" -gt 0 ]; then
        cur=$(stat -c %s "$WORK")
        if [ "$cur" -ne "$exp" ]; then
          tmp=$(mktemp)
          if [ "$cur" -ge "$exp" ]; then tail -c "$exp" "$WORK" > "$tmp"; else cp -f "$WORK" "$tmp"; fi
          mv -f "$tmp" "$WORK"
          echo "[rx-enforce] expected=$exp, had=$cur -> wrote=$(stat -c %s "$WORK")"
        fi
      fi
      cp -f "$WORK" "$PUB"
      echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"
    fi
  fi
done
