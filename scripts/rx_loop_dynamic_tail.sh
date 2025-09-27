#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# App's buffer (where it writes) and your published output
SRC="$PWD/data/incoming/vectors.bin"
PUB="$HOME/clearframe/data/incoming/vectors.bin"
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# Verbose + per-packet
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"

ARMED=0
BASE=0         # size at IDENT
EXP_LEN=""     # optional meta
EXP_SHA=""

# wait a short period after completion for late writes, or until size stops growing
settle_after_completion() {
  local deadline_ms=1500 step_ms=100 stable_needed=3
  local t=0 stable=0 prev=-1 cur=0
  while [ "$t" -lt "$deadline_ms" ]; do
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1))
      [ "$stable" -ge "$stable_needed" ] && break
    else
      stable=0
    fi
    prev="$cur"
    sleep 0.1
    t=$((t+step_ms))
  done
}

stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  # IDENT: arm & record baseline size (also reset buffer to be safe)
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    EXP_LEN=""; EXP_SHA=""
    : > "$SRC"
    BASE=0
    echo "[rx-arm] ident; reset $SRC (base=$BASE)"
  fi

  # metas (optional)
  if grep -q 'LEN=' <<<"$line"; then
    L=$(echo "$line" | grep -oE 'LEN=[0-9]+' | head -1 | sed 's/LEN=//')
    [ -n "$L" ] && EXP_LEN="$L" && echo "[rx-meta] LEN=$EXP_LEN"
  fi
  if grep -qi 'SHA=' <<<"$line"; then
    S=$(echo "$line" | grep -oEi 'SHA=[0-9a-f]{32,64}' | head -1 | sed 's/SHA=//' | tr 'A-F' 'a-f')
    [ -n "$S" ] && EXP_SHA="$S" && echo "[rx-meta] SHA=$EXP_SHA"
  fi

  # show every write as the buffer grows
  if [[ "$line" == "[RX] wrote "* ]]; then
    (( ARMED )) && echo "[rx-chunk] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
  fi

  # at completion: settle, then publish only the bytes added since IDENT (tail)
  if [[ "$line" == "[RX] completion"* ]]; then
    if (( ARMED )); then
      settle_after_completion
      end=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
      delta=$(( end - BASE ))
      if [ "$delta" -gt 0 ]; then
        tmp=$(mktemp)
        tail -c "$delta" "$SRC" > "$tmp" || :   # if SRC shorter, tail will just copy available
        install -m 600 "$tmp" "$PUB"
        rm -f "$tmp"
        echo "[rx] saved $PUB ($(stat -c %s "$PUB") bytes)"

        # optional verification if metas present (no enforcement)
        if [ -n "$EXP_LEN" ]; then
          [ "$delta" -eq "$EXP_LEN" ] \
            && echo "[rx-verify] length OK ($delta == $EXP_LEN)" \
            || echo "[rx-verify] length MISMATCH ($delta != $EXP_LEN)"
        fi
        if [ -n "$EXP_SHA" ]; then
          ACT_SHA=$(sha256sum "$PUB" | awk '{print $1}')
          [ "$ACT_SHA" = "$EXP_SHA" ] \
            && echo "[rx-verify] sha OK ($ACT_SHA)" \
            || echo "[rx-verify] sha MISMATCH ($ACT_SHA vs $EXP_SHA)"
        fi
      else
        echo "[rx-note] completion but no new data (delta=$delta)"
      fi
      ARMED=0
    else
      echo "[rx-note] completion while disarmed; ignoring"
    fi
  fi
done
