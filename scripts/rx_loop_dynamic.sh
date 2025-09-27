#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# where the app writes by default vs what we publish
SRC="$PWD/data/incoming/vectors.bin"
PUB="$HOME/clearframe/data/incoming/vectors.bin"
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# receiver env: verbose; print each UART packet; CFVX-only writes
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"

ARMED=0
SAW_DATA=0
EXP_LEN=""
EXP_SHA=""

# merge stderr so we see sniffer + all logs
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  # Arm on transmitter ID; reset buffer and metas
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    SAW_DATA=0
    EXP_LEN=""
    EXP_SHA=""
    : > "$SRC"
    echo "[rx-arm] ident seen; reset $SRC"
  fi

  # Capture optional metas (accepts anywhere in the stream)
  if grep -q 'LEN=' <<<"$line"; then
    L=$(echo "$line" | grep -oE 'LEN=[0-9]+' | head -1 | sed 's/LEN=//'); \
    [ -n "$L" ] && EXP_LEN="$L" && echo "[rx-meta] expected length: $EXP_LEN bytes"
  fi
  if grep -qi 'SHA=' <<<"$line"; then
    S=$(echo "$line" | grep -oEi 'SHA=[0-9a-f]{32,64}' | head -1 | sed 's/SHA=//' | tr 'A-F' 'a-f'); \
    [ -n "$S" ] && EXP_SHA="$S" && echo "[rx-meta] expected SHA: $EXP_SHA"
  fi

  # Every write the app performs (CFVX chunk): show current buffer size
  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )) && [ -f "$SRC" ]; then
      BYTES=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
      SAW_DATA=1
      echo "[rx-chunk] buffer now ${BYTES} bytes"
    fi
  fi

  # Only finalize on completion; publish EXACTLY what was received (no truncation)
  if [[ "$line" == "[RX] completion"* ]]; then
    if (( ARMED )) && [ -s "$SRC" ]; then
      cp -f "$SRC" "$PUB"
      chmod 600 "$PUB"
      BYTES=$(stat -c %s "$PUB" 2>/dev/null || echo 0)
      echo "[rx] saved $PUB (${BYTES} bytes)"

      # Optional verification if metas were provided
      if [ -n "$EXP_LEN" ]; then
        if [ "$BYTES" -eq "$EXP_LEN" ]; then
          echo "[rx-verify] length OK (${BYTES} == ${EXP_LEN})"
        else
          echo "[rx-verify] length MISMATCH (${BYTES} != ${EXP_LEN})"
        fi
      fi
      if [ -n "$EXP_SHA" ]; then
        ACT_SHA=$(sha256sum "$PUB" | awk '{print $1}')
        if [ "$ACT_SHA" = "$EXP_SHA" ]; then
          echo "[rx-verify] sha OK ($ACT_SHA)"
        else
          echo "[rx-verify] sha MISMATCH (got $ACT_SHA vs $EXP_SHA)"
        fi
      fi
    else
      echo "[rx-note] completion with no data yet; staying ready for next loop"
    fi
    ARMED=0
    SAW_DATA=0
  fi
done
