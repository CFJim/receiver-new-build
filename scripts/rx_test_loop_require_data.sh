#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
WORK="$WORKDIR/vectors.bin"; PUB="$PUBDIR/vectors.bin"
mkdir -p "$WORKDIR" "$PUBDIR"; : > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # show every UART packet (hex)
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # receiver only writes CFVX frames
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$WORKDIR"

cfvx_len () { python3 - "$1" <<'PY'
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

ARMED=0
SAW_DATA=0

stdbuf -oL -eL python -u app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # Arm on ID (new loop)
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1; SAW_DATA=0
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  # Track each write; detect CFVX header; print sizes
  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )); then
      if [ -f "$WORK" ]; then
        bytes=$(stat -c %s "$WORK" 2>/dev/null || echo 0)
        echo "[rx-packet] wrote chunk; buffer now ${bytes} bytes"
        # flag once we see a CFVX header in buffer
        if head -c 6 "$WORK" 2>/dev/null | grep -q '^CFVX01$'; then
          SAW_DATA=1
        fi
      fi
    fi
  fi

  # Only publish on completion if we've actually seen CFVX data
  if [[ "$line" == "[RX] completion"* ]]; then
    if (( ARMED && SAW_DATA )) && [ -s "$WORK" ]; then
      exp=$(cfvx_len "$WORK" || echo 0)
      if [ "$exp" -gt 0 ]; then
        cur=$(stat -c %s "$WORK")
        if [ "$cur" -ne "$exp" ]; then
          tmp=$(mktemp)
          if [ "$cur" -ge "$exp" ]; then tail -c "$exp" "$WORK" > "$tmp"; else cp -f "$WORK" "$tmp"; fi
          mv -f "$tmp" "$WORK"
          echo "[rx-enforce] expected=$exp had=$cur -> trimmed=$(stat -c %s "$WORK")"
        fi
        cp -f "$WORK" "$PUB"
        echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"
      fi
    else
      echo "[rx-skip] completion without data; waiting for CFVX"
    fi
    # disarm after completion; next loop will re-arm on ident
    ARMED=0
  fi
done
