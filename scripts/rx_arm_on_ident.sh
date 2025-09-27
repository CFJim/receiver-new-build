#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# Work file (where the app writes) and public file (what you care about)
WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

# Receiver env: show every packet, save only CFVX, write to WORKDIR
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # hex-dump each UART packet
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # only CFVX payloads are written by the app
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$WORKDIR"

# Helper: expected CFVX length from header (robust for future payloads)
cfvx_len () {
  python3 - "$1" <<'PY'
import sys,struct,os
p=sys.argv[1]
try:
  if os.path.getsize(p) < 28: print(0); raise SystemExit
  with open(p,'rb') as f:
    if f.read(6)!=b'CFVX01': print(0); raise SystemExit
    f.read(1); f.read(16); f.read(1)
    vcnt, ecnt = struct.unpack('<HH', f.read(4))
    print(28 + vcnt*12 + ecnt*4)
except Exception: print(0)
PY
}

ARMED=0   # becomes 1 after we see an [RX] ident

stdbuf -oL -eL python -u app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # Arm on transmitter ID, start fresh buffer
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  # Only consider completion/write events if ARMED
  if [[ "$line" == "[RX] wrote "* || "$line" == "[RX] completion"* ]]; then
    if (( ! ARMED )); then
      echo "[rx-skip] completion/write while disarmed; ignoring"
      continue
    fi

    # If we have bytes, publish only valid CFVX and clamp to header-declared length
    if [ -s "$WORK" ]; then
      exp=$(cfvx_len "$WORK" || echo 0)
      if [ "$exp" -gt 0 ]; then
        cur=$(stat -c %s "$WORK")
        if [ "$cur" -ne "$exp" ]; then
          tmp=$(mktemp)
          if [ "$cur" -ge "$exp" ]; then tail -c "$exp" "$WORK" > "$tmp"; else cp -f "$WORK" "$tmp"; fi
          mv -f "$tmp" "$WORK"
          echo "[rx-enforce] expected=$exp had=$cur -> wrote=$(stat -c %s "$WORK")"
        fi
        cp -f "$WORK" "$PUB"
        echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"
      else
        echo "[rx-skip] buffer is not valid CFVX; nothing published"
      fi
    else
      echo "[rx-skip] empty buffer; nothing to publish"
    fi

    # Disarm until next ident to avoid mid-loop noise
    ARMED=0
  fi
done
