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
BASH

chmod +x ~/cfreceiver/scripts/rx_arm_on_ident.sh
# 2) run it
~/cfreceiver/scripts/rx_arm_on_ident.sh
ls -l --block-size=1 ~/clearframe/data/incoming/vectors.bin
sha256sum ~/clearframe/data/incoming/vectors.bin
# expect: 172 bytes and 85e03997c14e45c15e9d6eb0ca42dd079f4f0430f1897db420fa3fd8f762dfcf
# 0) stop any running receiver
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 1) create the test wrapper
mkdir -p ~/cfreceiver/scripts ~/clearframe/data/incoming
tee ~/cfreceiver/scripts/rx_test_loop_print_packets.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

# Work buffer (where the app writes) and published file (what you care about)
WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

# Receiver env: print every UART packet, save only CFVX, overwrite buffer
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # per-UART packet hex dump
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # only CFVX payloads are written by the app
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$WORKDIR"

# Helper: expected CFVX length from header (generic—works beyond this test)
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

ARMED=0

# Run the stock receiver and watch its log lines
stdbuf -oL -eL python -u app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # Arm on transmitter ID and reset the buffer
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  # On any write line from the app, print the current buffer size (per-chunk visibility)
  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )); then
      if [ -f "$WORK" ]; then
        echo "[rx-packet] wrote chunk; buffer now $(stat -c %s "$WORK") bytes"
      fi
    else
      echo "[rx-skip] write while disarmed; ignoring"
    fi
  fi

  # On completion or write, if armed, check/publish the CFVX file
  if [[ "$line" == "[RX] completion"* || "$line" == "[RX] wrote "* ]]; then
    if (( ! ARMED )); then
      continue
    fi
    if [ -s "$WORK" ]; then
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
    fi
  fi

  # Disarm after a completion to wait for the next loop’s ID
  if [[ "$line" == "[RX] completion"* ]]; then
    ARMED=0
  fi
done
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# 2) run it
~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# stop any running receiver
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# write a clean wrapper
tee ~/cfreceiver/scripts/rx_test_loop_print_packets.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # hex-dump every UART packet
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # only CFVX gets written by the app
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$WORKDIR"

# compute expected CFVX length from header (generic)
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

ARMED=0

stdbuf -oL -eL python -u app.py --role receiver | \
while IFS= read -r line; do
  echo "$line"

  # arm on ID and reset the work buffer
  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  # whenever the app writes a chunk, print current buffer size
  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )) && [ -f "$WORK" ]; then
      echo "[rx-packet] wrote chunk; buffer now $(stat -c %s "$WORK") bytes"
    fi
  fi

  # on completion or write, if armed, clamp & publish CFVX
  if [[ "$line" == "[RX] completion"* || "$line" == "[RX] wrote "* ]]; then
    if (( ! ARMED )); then
      continue
    fi
    if [ -s "$WORK" ]; then
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
    fi
  fi

  # disarm after completion to await the next loop
  if [[ "$line" == "[RX] completion"* ]]; then
    ARMED=0
  fi
done
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# run it
~/cfreceiver/scripts/rx_test_loop_print_packets.sh
watch -n 1 '
  f="$HOME/clearframe/data/incoming/vectors.bin";
  [ -f "$f" ] && stat -c "%y %n %s bytes" "$f"; sha256sum "$f" 2>/dev/null || true
'
mkdir -p ~/.config/systemd/user ~/clearframe/logs
tee ~/.config/systemd/user/cf-rx.service >/dev/null <<'UNIT'
[Unit]
Description=Clearframe RX test mode (arm on ID, print every packet, CFVX-only save)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash -lc '/home/receiver/cfreceiver/scripts/rx_test_loop_print_packets.sh'
Restart=always
RestartSec=2
StandardOutput=append:/home/receiver/clearframe/logs/cf-rx.service.log
StandardError=append:/home/receiver/clearframe/logs/cf-rx.service.log

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable --now cf-rx.service
journalctl --user -u cf-rx.service -f
# kill any old receiver process
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# run the test wrapper: arms on ID, prints every packet, overwrites one 172-byte file each loop
~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# stop our wrapper and any stray receivers
pkill -f 'rx_test_loop_print_packets.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# see who (if anyone) still has the port
sudo fuser -v /dev/ttyAMA0 || true
sudo lsof -nP /dev/ttyAMA0 || true
# stop our wrapper & any stray receivers
pkill -f 'rx_test_loop_print_packets.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# kill serial login consoles that often steal the UART
sudo systemctl stop    serial-getty@ttyAMA0.service 2>/dev/null || true
sudo systemctl disable serial-getty@ttyAMA0.service 2>/dev/null || true
sudo systemctl stop    serial-getty@ttyS0.service   2>/dev/null || true
sudo systemctl disable serial-getty@ttyS0.service   2>/dev/null || true
cd ~/cfreceiver
. .venv/bin/activate
python - <<'PY'
import re, pathlib
p = pathlib.Path('clearframe/lora/io.py')
s = p.read_text()
def add_exclusive(m):
    args = m.group(1)
    return m.group(0) if 'exclusive=' in args else f"serial.Serial({args}, exclusive=True)"
ns, cnt = re.subn(r"serial\.Serial\(([^)]*)\)", add_exclusive, s, count=1, flags=re.S)
if cnt:
    p.write_text(ns); print("Patched: added exclusive=True to serial.Serial(...)")
else:
    print("Note: serial.Serial(...) not found or already patched")
PY

python - <<'PY'
import serial, time
try:
    s=serial.Serial('/dev/ttyAMA0', 9600, timeout=1, exclusive=True)
    print("Opened /dev/ttyAMA0 OK")
    for _ in range(3):
        b=s.read(64); print("read", len(b), "bytes"); time.sleep(1)
except Exception as e:
    print("ERR:", e)
PY

# new wrapper that restarts the inner app if it crashes (e.g., SerialException)
tee ~/cfreceiver/scripts/rx_test_loop_autorestart.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"; PUB="$PUBDIR/vectors.bin"; : > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
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

while true; do
  ARMED=0
  stdbuf -oL -eL python -u app.py --role receiver | \
  while IFS= read -r line; do
    echo "$line"
    [[ "$line" == "[RX] ident:"* ]] && { ARMED=1; : > "$WORK"; echo "[rx-arm] armed on ident; buffer reset -> $WORK"; }
    if [[ "$line" == "[RX] wrote "* ]]; then
      (( ARMED )) && [ -f "$WORK" ] && echo "[rx-packet] wrote chunk; buffer now $(stat -c %s "$WORK") bytes"
    fi
    if [[ "$line" == "[RX] completion"* || "$line" == "[RX] wrote "* ]]; then
      (( ARMED )) || continue
      if [ -s "$WORK" ]; then
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
      fi
    fi
    [[ "$line" == "[RX] completion"* ]] && ARMED=0
  done
  ec=$?; echo "[rx-wrap] app exited (code $ec); restarting in 1s..." >&2; sleep 1
done
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_autorestart.sh
# run it
~/cfreceiver/scripts/rx_test_loop_autorestart.sh
# stop our wrappers / services / stray receivers
pkill -f 'rx_test_loop' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
systemctl --user stop cf-rx.service 2>/dev/null || true
# kill serial login consoles that often grab the UART
sudo systemctl stop    serial-getty@ttyAMA0.service 2>/dev/null || true
sudo systemctl disable serial-getty@ttyAMA0.service 2>/dev/null || true
sudo systemctl stop    serial-getty@ttyS0.service   2>/dev/null || true
sudo systemctl disable serial-getty@ttyS0.service   2>/dev/null || true
cd ~/cfreceiver
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; }
python - <<'PY'
import json, pathlib
p = pathlib.Path('config/current.json')
cfg = {}
if p.exists():
    cfg = json.loads(p.read_text())
cfg.setdefault('serial', {})
cfg['serial']['port'] = '/dev/serial0'
p.write_text(json.dumps(cfg, indent=2))
print("Updated:", p, "-> serial.port=/dev/serial0")
PY

python - <<'PY'
import re, pathlib
p = pathlib.Path('clearframe/lora/io.py')
s = p.read_text()
def add_exclusive(m):
    args = m.group(1)
    return m.group(0) if 'exclusive=' in args else f"serial.Serial({args}, exclusive=True)"
ns, cnt = re.subn(r"serial\.Serial\(([^)]*)\)", add_exclusive, s, count=1, flags=re.S)
if cnt:
    p.write_text(ns); print("Patched: exclusive=True added to serial.Serial(...)")
else:
    print("Note: serial.Serial(...) already has exclusive=True (or not found)")
PY

python - <<'PY'
import serial, time
try:
    s=serial.Serial('/dev/serial0', 9600, timeout=1, exclusive=True)
    print("Opened /dev/serial0 OK")
    for _ in range(3):
        b=s.read(64); print("read", len(b), "bytes"); time.sleep(0.5)
except Exception as e:
    print("ERR:", e)
PY

~/cfreceiver/scripts/rx_test_loop_autorestart.sh
# point RX at /dev/serial0
cd ~/cfreceiver && . .venv/bin/activate
python - <<'PY'
import json, pathlib
p=pathlib.Path('config/current.json'); cfg={}
if p.exists(): cfg=json.loads(p.read_text())
cfg.setdefault('serial',{})['port']='/dev/serial0'
p.write_text(json.dumps(cfg,indent=2)); print("serial.port=/dev/serial0")
PY

# (already patched) ensure exclusive open is present; then run the wrapper again
~/cfreceiver/scripts/rx_test_loop_autorestart.sh
# on the RX Pi
pkill -f 'rx_test_loop' 2>/dev/null || true
mkdir -p ~/cfreceiver/scripts ~/clearframe/data/_rxwork ~/clearframe/data/incoming
tee ~/cfreceiver/scripts/rx_test_loop_require_data.sh >/dev/null <<'BASH'
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
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_require_data.sh
# run it
~/cfreceiver/scripts/rx_test_loop_require_data.sh
# 1) Stop any previous RX wrappers
pkill -f 'rx_test_loop_' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 2) Rebuild the RX wrapper to capture BOTH stdout and stderr (2>&1)
tee ~/cfreceiver/scripts/rx_test_loop_print_packets.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # hex-dump every UART packet
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # only CFVX is written by the app
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

# Merge stderr into stdout so we see all lines from the app (sniffer etc.)
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | \
while IFS= read -r line; do
  echo "$line"

  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    SAW_DATA=0
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )) && [ -f "$WORK" ]; then
      bytes=$(stat -c %s "$WORK" 2>/dev/null || echo 0)
      echo "[rx-packet] wrote chunk; buffer now ${bytes} bytes"
      # detect CFVX header presence
      head -c 6 "$WORK" 2>/dev/null | grep -q '^CFVX01$' && SAW_DATA=1 || true
    fi
  fi

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
      echo "[rx-skip] completion without CFVX data; waiting for data"
    fi
    ARMED=0
  fi
done
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# 3) Run it
~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# 1) Stop any previous RX wrappers
pkill -f 'rx_test_loop_' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 2) Rebuild the RX wrapper to capture BOTH stdout and stderr (2>&1)
tee ~/cfreceiver/scripts/rx_test_loop_print_packets.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

WORKDIR="$HOME/clearframe/data/_rxwork"
PUBDIR="$HOME/clearframe/data/incoming"
mkdir -p "$WORKDIR" "$PUBDIR"
WORK="$WORKDIR/vectors.bin"
PUB="$PUBDIR/vectors.bin"
: > "$WORK"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1      # hex-dump every UART packet
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01     # only CFVX is written by the app
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

# Merge stderr into stdout so we see all lines from the app (sniffer etc.)
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | \
while IFS= read -r line; do
  echo "$line"

  if [[ "$line" == "[RX] ident:"* ]]; then
    ARMED=1
    SAW_DATA=0
    : > "$WORK"
    echo "[rx-arm] armed on ident; buffer reset -> $WORK"
  fi

  if [[ "$line" == "[RX] wrote "* ]]; then
    if (( ARMED )) && [ -f "$WORK" ]; then
      bytes=$(stat -c %s "$WORK" 2>/dev/null || echo 0)
      echo "[rx-packet] wrote chunk; buffer now ${bytes} bytes"
      # detect CFVX header presence
      head -c 6 "$WORK" 2>/dev/null | grep -q '^CFVX01$' && SAW_DATA=1 || true
    fi
  fi

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
      echo "[rx-skip] completion without CFVX data; waiting for data"
    fi
    ARMED=0
  fi
done
BASH

chmod +x ~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# 3) Run it
~/cfreceiver/scripts/rx_test_loop_print_packets.sh
# --- RX: clean minimal loop for this 172-byte test ---
# 0) stop anything stale
pkill -f 'rx_test_loop' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 1) create a rock-solid wrapper (no Python helpers, no fragile quoting)
cat > ~/cfreceiver/scripts/rx_test_172.sh <<'EOF'
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
EOF

chmod +x ~/cfreceiver/scripts/rx_test_172.sh
# 2) run it
~/cfreceiver/scripts/rx_test_172.sh
# 0) stop anything stale
pkill -f 'rx_test_' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 1) create a robust follower of the app's default output path
cat > ~/cfreceiver/scripts/rx_follow_app_path_172.sh <<'EOF'
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
EOF

chmod +x ~/cfreceiver/scripts/rx_follow_app_path_172.sh
# 2) run it
~/cfreceiver/scripts/rx_follow_app_path_172.sh
# 0) stop anything stale
pkill -f 'rx_loop_require_data_clean.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 1) write a minimal, robust wrapper
cat > ~/cfreceiver/scripts/rx_loop_require_data_clean.sh <<'BASH'
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
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_require_data_clean.sh
# 2) run it
~/cfreceiver/scripts/rx_loop_require_data_clean.sh
# stop anything stale
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
cd ~/cfreceiver && . .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }
# prefer the stable alias; fall back to AMA0 if needed
export CF_LORA_PORT=/dev/serial0
# verbose + save only CFVX to the repo’s default path
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_RX_OVERWRITE=1
export CF_WIRE_MAGIC=CFVX01
export CF_RX_SAVE_DIR="$PWD/data/incoming"
# run the receiver (merge stderr so you see *everything*)
stdbuf -oL -eL python -u app.py --role receiver 2>&1
# restart RX with the alias (already exported above)
export CF_LORA_PORT=/dev/serial0
# patch exclusive=True once (idempotent)
cd ~/cfreceiver && . .venv/bin/activate
python - <<'PY'
import re, pathlib
p=pathlib.Path('clearframe/lora/io.py'); s=p.read_text()
def add_exc(m): 
    args=m.group(1)
    return m.group(0) if 'exclusive=' in args else f"serial.Serial({args}, exclusive=True)"
ns,c=re.subn(r"serial\.Serial\(([^)]*)\)", add_exc, s, count=1, flags=re.S)
if c: p.write_text(ns); print("exclusive=True added")
else: print("exclusive already set or not found")
PY

# relaunch receiver (same as step 1)
stdbuf -oL -eL python -u app.py --role receiver 2>&1
# stop anything stale
pkill -f 'rx_loop_dynamic.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# create the wrapper
tee ~/cfreceiver/scripts/rx_loop_dynamic.sh >/dev/null <<'BASH'
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
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_dynamic.sh
# run it
~/cfreceiver/scripts/rx_loop_dynamic.sh
# stop anything stale
pkill -f 'rx_loop_dynamic_tail.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
tee ~/cfreceiver/scripts/rx_loop_dynamic_tail.sh >/dev/null <<'BASH'
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
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_dynamic_tail.sh
# run it
~/cfreceiver/scripts/rx_loop_dynamic_tail.sh
# stop anything stale
pkill -f 'rx_loop_extract_last_cfvx.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# wrapper: arm on ID, print every write, and on completion publish ONLY the last CFVX frame
tee ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh >/dev/null <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate || { python3 -m venv .venv && . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

SRC="$PWD/data/incoming/vectors.bin"            # where the app writes
PUB="$HOME/clearframe/data/incoming/vectors.bin"# what we overwrite each loop
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"

ARMED=0

extract_last_cfvx () {
python - "$SRC" "$PUB" <<'PY'
import sys, os, struct, hashlib
src, pub = sys.argv[1], sys.argv[2]
try:
    with open(src,'rb') as f: data = f.read()
except FileNotFoundError:
    sys.exit(1)

MAG=b'CFVX01'
pos = data.rfind(MAG)
if pos < 0:
    print("[rx-extract] no CFVX header found"); sys.exit(2)

if len(data) < pos+28:
    print("[rx-extract] incomplete header at tail"); sys.exit(3)

i = pos + 6
i += 1              # flags
i += 16             # origin
i += 1              # reserved
vcnt, ecnt = struct.unpack('<HH', data[i:i+4])
length = 28 + vcnt*12 + ecnt*4

if len(data) < pos + length:
    print(f"[rx-extract] trailing CFVX incomplete (need {length}, have {len(data)-pos})"); sys.exit(4)

frame = data[pos:pos+length]
os.makedirs(os.path.dirname(pub), exist_ok=True)
with open(pub,'wb') as g: g.write(frame)
print(f"[rx] saved {pub} ({len(frame)} bytes) sha256={hashlib.sha256(frame).hexdigest()}")
PY
}

# merge stderr so we see *all* app logs/sniffer
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"              # clear buffer at start of loop
      echo "[rx-arm] ident; reset $SRC"
      ;;
    "[RX] wrote "*)
      (( ARMED )) && echo "[rx-chunk] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
      ;;
    "[RX] completion"*)
      if (( ARMED )); then
        # small settle to catch late writes
        sleep 0.3
        extract_last_cfvx
      else
        echo "[rx-note] completion while disarmed; ignored"
      fi
      ARMED=0
      ;;
  esac
done
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh
# clean start and run
rm -f ~/cfreceiver/data/incoming/vectors.bin ~/clearframe/data/incoming/vectors.bin
~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh
# backup any old copies
mkdir -p ~/cfreceiver/scripts
cp -a ~/cfreceiver/scripts/_extract_last_cfvx.py ~/cfreceiver/scripts/_extract_last_cfvx.py.bak 2>/dev/null || true
# write a clean extractor
cat > ~/cfreceiver/scripts/_extract_last_cfvx.py <<'PY'
#!/usr/bin/env python3
import sys, os, struct, hashlib

if len(sys.argv) != 3:
    print("usage: _extract_last_cfvx.py <src> <dest>", file=sys.stderr); sys.exit(2)

src, dest = sys.argv[1], sys.argv[2]
try:
    with open(src,'rb') as f:
        data = f.read()
except FileNotFoundError:
    print("[rx-extract] source not found", file=sys.stderr); sys.exit(1)

MAG = b'CFVX01'
pos = data.rfind(MAG)
if pos < 0:
    print("[rx-extract] no CFVX header found"); sys.exit(3)

need_header = pos + 28
if len(data) < need_header:
    print("[rx-extract] incomplete header at tail"); sys.exit(4)

i = pos + 6           # magic
i += 1                # flags
i += 16               # origin
i += 1                # reserved
vcnt, ecnt = struct.unpack('<HH', data[i:i+4])
length = 28 + vcnt*12 + ecnt*4

have = len(data) - pos
if have < length:
    print(f"[rx-extract] trailing CFVX incomplete (need {length}, have {have})"); sys.exit(5)

frame = data[pos:pos+length]
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest,'wb') as g:
    g.write(frame)
print(f"[rx] saved {dest} ({len(frame)} bytes) sha256={hashlib.sha256(frame).hexdigest()}")
PY

chmod +x ~/cfreceiver/scripts/_extract_last_cfvx.py
python3 -m py_compile ~/cfreceiver/scripts/_extract_last_cfvx.py
# backup old wrapper
cp -a ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh.bak 2>/dev/null || true
# write a clean wrapper
cat > ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail

cd "$HOME/cfreceiver"
. .venv/bin/activate 2>/dev/null || { python3 -m venv .venv; . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

SRC="$PWD/data/incoming/vectors.bin"              # app's buffer file
PUB="$HOME/clearframe/data/incoming/vectors.bin"  # published file per loop
EXTRACT="$HOME/cfreceiver/scripts/_extract_last_cfvx.py"

mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# verbose receive; CFVX-only writes; show every UART packet
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"

ARMED=0

# small settle to catch late writes post-completion
settle_after_completion() {
  local prev=-1 cur=0 stable=0
  for _ in $(seq 1 15); do   # ~1.5s at 100ms steps
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1))
      [ "$stable" -ge 3 ] && break
    else
      stable=0
    fi
    prev="$cur"
    sleep 0.1
  done
}

# run the app, merge stderr so we see everything
stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"

  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"    # clear buffer for new loop
      echo "[rx-arm] ident; reset $SRC"
      ;;

    "[RX] wrote "*)
      (( ARMED )) && echo "[rx-chunk] buffer=$(stat -c %s "$SRC" 2>/dev/null || echo 0) bytes"
      ;;

    "[RX] completion"*)
      if (( ARMED )); then
        settle_after_completion
        # extract last complete CFVX frame in buffer and publish it
        "$EXTRACT" "$SRC" "$PUB" || echo "[rx-extract] no complete CFVX to publish this loop"
      else
        echo "[rx-note] completion while disarmed; ignored"
      fi
      ARMED=0
      ;;
  esac
done
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh
bash -n ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
pkill -f 'rx_loop_extract_last_cfvx.sh' 2>/dev/null || true
rm -f ~/cfreceiver/data/incoming/vectors.bin ~/clearframe/data/incoming/vectors.bin
~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh
# stop anything stale
pkill -f 'rx_loop_extract_last_cfvx_watch.sh' 2>/dev/null || true
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
# 1) CFVX extractor (standalone, idempotent)
mkdir -p ~/cfreceiver/scripts
cat > ~/cfreceiver/scripts/_extract_last_cfvx.py <<'PY'
#!/usr/bin/env python3
import sys, os, struct, hashlib
if len(sys.argv)!=3:
    print("usage: _extract_last_cfvx.py <src> <dest>", file=sys.stderr); sys.exit(2)
src, dest = sys.argv[1], sys.argv[2]
try:
    with open(src,'rb') as f: data = f.read()
except FileNotFoundError:
    print("[rx-extract] source not found", file=sys.stderr); sys.exit(1)
MAG=b'CFVX01'
pos=data.rfind(MAG)
if pos<0: print("[rx-extract] no CFVX header found"); sys.exit(3)
need=pos+28
if len(data)<need: print("[rx-extract] incomplete header at tail"); sys.exit(4)
i=pos+6; i+=1; i+=16; i+=1
vcnt,ecnt=struct.unpack('<HH', data[i:i+4])
length=28+vcnt*12+ecnt*4
have=len(data)-pos
if have<length: print(f"[rx-extract] trailing CFVX incomplete (need {length}, have {have})"); sys.exit(5)
frame=data[pos:pos+length]
os.makedirs(os.path.dirname(dest), exist_ok=True)
with open(dest,'wb') as g: g.write(frame)
print(f"[rx] saved {dest} ({len(frame)} bytes) sha256={hashlib.sha256(frame).hexdigest()}")
PY

chmod +x ~/cfreceiver/scripts/_extract_last_cfvx.py
# 2) RX loop with size watcher
cat > ~/cfreceiver/scripts/rx_loop_extract_last_cfvx_watch.sh <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$HOME/cfreceiver"
. .venv/bin/activate 2>/dev/null || { python3 -m venv .venv; . .venv/bin/activate; python -m pip -q install -U pip pyserial; }

SRC="$PWD/data/incoming/vectors.bin"              # app buffer
PUB="$HOME/clearframe/data/incoming/vectors.bin"  # published file per loop
EXTRACT="$HOME/cfreceiver/scripts/_extract_last_cfvx.py"
mkdir -p "$(dirname "$SRC")" "$(dirname "$PUB")"
: > "$SRC"

# Receiver env
export PYTHONUNBUFFERED=1
export CF_LOG_LEVEL=DEBUG
export CF_SERIAL_SNIFFER=1
export CF_RX_ASCII=0
export CF_RX_NORMALIZE=0
export CF_WIRE_MAGIC=CFVX01
export CF_RX_OVERWRITE=1
export CF_RX_SAVE_DIR="$PWD/data/incoming"
# (optional) prefer alias; uncomment if needed:
# export CF_LORA_PORT=/dev/serial0

ARMED=0
WATCHPID=""

start_watch() {
  local prev
  prev=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
  ( 
    p="$prev"
    while :; do
      cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
      if [ "$cur" != "$p" ]; then
        echo "[rx-chunk] buffer=${cur} bytes"
        p="$cur"
      fi
      sleep 0.10
    done
  ) & WATCHPID=$!
}

stop_watch() { [ -n "${WATCHPID:-}" ] && kill "$WATCHPID" 2>/dev/null || true; WATCHPID=""; }

settle_after_completion() {
  local prev=-1 cur=0 stable=0
  for _ in $(seq 1 15); do   # ~1.5s max, exit early when stable
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    if [ "$cur" -eq "$prev" ]; then
      stable=$((stable+1)); [ "$stable" -ge 3 ] && break
    else
      stable=0
    fi
    prev="$cur"; sleep 0.10
  done
}

stdbuf -oL -eL python -u app.py --role receiver 2>&1 | while IFS= read -r line; do
  echo "$line"
  case "$line" in
    "[RX] ident:"*)
      ARMED=1
      : > "$SRC"
      echo "[rx-arm] ident; reset $SRC"
      stop_watch; start_watch
      ;;
    "[RX] completion"*)
      if (( ARMED )); then
        settle_after_completion
        stop_watch
        "$EXTRACT" "$SRC" "$PUB" || echo "[rx-extract] no complete CFVX to publish this loop"
      else
        echo "[rx-note] completion while disarmed; ignored"
      fi
      ARMED=0
      ;;
  esac
done
BASH

chmod +x ~/cfreceiver/scripts/rx_loop_extract_last_cfvx_watch.sh
# 3) Clean start & run
pkill -f 'python .*app.py --role receiver' 2>/dev/null || true
pkill -f 'rx_loop_extract_last_cfvx_watch.sh' 2>/dev/null || true
rm -f ~/cfreceiver/data/incoming/vectors.bin ~/clearframe/data/incoming/vectors.bin
~/cfreceiver/scripts/rx_loop_extract_last_cfvx_watch.sh
cd ~
cd ~/cfreceiver
# Ensure the scripts are inside the repo's scripts dir
mkdir -p scripts
# Copy in the tested wrappers/extractor if they’re not already here
cp -f ~/cfreceiver/scripts/_extract_last_cfvx.py scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_loop_extract_last_cfvx.sh scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_loop_extract_last_cfvx_watch.sh scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_loop_dynamic.sh scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_armed_save_172.sh scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_test_loop_print_packets.sh scripts/ 2>/dev/null || true
cp -f ~/cfreceiver/scripts/rx_test_loop_autorestart.sh scripts/ 2>/dev/null || true
# Make sure they’re executable
chmod +x scripts/*.sh 2>/dev/null || true
# If you applied the exclusive=True patch, include it:
#   file: clearframe/lora/io.py  (search for serial.Serial(..., exclusive=True))
# It’ll be picked up by `git add -A` below.
git fetch origin
BASE_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD | cut -d/ -f2)"
git switch -c "feature/rx-loop-2025-09-27" "origin/${BASE_BRANCH}"
git add -A
git status
git commit -m "RX loop testing: per-packet prints, CFVX last-frame publish, exclusive=True on serial" || echo "Nothing to commit."
git push -u origin "feature/rx-loop-2025-09-27"
# Receiver
cd ~/cfreceiver
git tag -a txrx-test-2025-09-27 -m "Clearframe TXRX loop test (RX)"
git push origin txrx-test-2025-09-27
echo "Hello Blade" | sudo tee /dev/rfcomm0
echo "Hello from Pi $(date +%H:%M:%S)" | sudo tee /dev/rfcomm0
sudo bluetoothctl
sudo rfcomm listen hci0 1
bluetoothctl show
sudo sdptool add SP
sudo rfcomm listen hci0 1
sudo apt-get update
sudo apt-get install -y bluetooth bluez python3-pip
pip3 install pybluez
# 1) Install BlueZ + PyBluez from apt (no pip)
sudo apt update
sudo apt install -y bluetooth bluez python3-bluez
# 2) Bring up Bluetooth and make the Pi discoverable/pairable (once)
sudo bluetoothctl <<'EOF'
power on
agent on
default-agent
system-alias CF-RX
pairable on
discoverable on
EOF

# 3) Run a simple SPP server (Python using system PyBluez)
cat > ~/cf_spp_server.py <<'PY'
#!/usr/bin/env python3
from bluetooth import BluetoothSocket, RFCOMM, advertise_service, SERIAL_PORT_CLASS, SERIAL_PORT_PROFILE
import time

UUID = "00001101-0000-1000-8000-00805F9B34FB"  # SPP
sock = BluetoothSocket(RFCOMM)
sock.bind(("", 1))
sock.listen(1)
advertise_service(sock, "CF-RX", service_id=UUID,
                  service_classes=[UUID, SERIAL_PORT_CLASS],
                  profiles=[SERIAL_PORT_PROFILE])
print("[SPP] Advertising CF-RX on channel 1")
while True:
    client, addr = sock.accept()
    print("[SPP] Connected:", addr)
    try:
        i = 0
        while True:
            try:
                data = client.recv(1024)
                if data:
                    print("[RX]", data.decode("utf-8","ignore").strip())
            except Exception:
                pass
            client.send(f"CFRX {i}\n".encode("utf-8"))
            i += 1
            time.sleep(1.0)
    except Exception as e:
        print("[SPP] link closed:", e)
    finally:
        try: client.close()
        except: pass
PY

chmod +x ~/cf_spp_server.py
sudo hciconfig hci0 up
sudo ~/cf_spp_server.py
sudo hciconfig hci0 up
sudo hciconfig hci0 piscan      # enable page/inquiry scan (discoverable + connectable)
hciconfig hci0
# Add SPP service record
sudo sdptool add SP
# Confirm service is visible
sdptool browse local
sudo nano /lib/systemd/system/bluetooth.service
sudo systemctl daemon-reexec
sudo systemctl restart bluetooth
sudo sdptool add SP
sdptool browse local
sudo hciconfig hci0 up piscan
sudo bluetoothctl
[bluetooth]# discoverable on
[bluetooth]# pairable on
[bluetooth]# system-alias CF-RX
[bluetooth]# quit
sudo hciconfig hci0 up piscan
sudo bluetoothctl
[bluetooth]# discoverable on
[bluetooth]# pairable on
[bluetooth]# system-alias CF-RX
[bluetooth]# quit
sudo systemctl restart bluetooth
sudo hciconfig hci0 up piscan
sudo sdptool add SP
sudo systemctl restart bluetooth
sudo hciconfig hci0 up piscan
sudo bluetoothctl
[bluetooth]# system-alias CF-RX
[bluetooth]# quit
sudo bluetoothctl
[bluetooth]# system-alias CF-RX
[bluetooth]# quit
sudo nano /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
bluetoothctl show | grep Alias
# A) Persisted alias via bluetoothctl (usually enough)
sudo bluetoothctl <<'EOF'
system-alias CF-RX
quit
EOF

# B) Also set Name in main.conf (append a [General] section)
sudo bash -c 'printf "\n[General]\nName = CF-RX\n" >> /etc/bluetooth/main.conf'
# See current ExecStart path (copy it for the next step)
systemctl cat bluetooth | sed -n '1,120p'
# Create a drop-in override and add -C to ExecStart
sudo systemctl edit bluetooth
sudo systemctl daemon-reload
sudo systemctl restart bluetooth
sudo tee /usr/local/bin/cf-bt-setup.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -e
# Make adapter up + discoverable/connectable
hciconfig hci0 up piscan || true
# Ensure nice alias every boot (belt-and-suspenders)
bluetoothctl <<EOF
system-alias CF-RX
discoverable on
pairable on
EOF
# Publish Serial Port Profile (SPP) each boot
sdptool add SP || true
SH

sudo chmod +x /usr/local/bin/cf-bt-setup.sh
sudo tee /etc/systemd/system/cf-bt-setup.service >/dev/null <<'UNIT'
[Unit]
Description=ClearFrame Bluetooth SPP/Discoverable setup
After=bluetooth.service
Requires=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-bt-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now cf-bt-setup.service
sudo tee /etc/systemd/system/cf-rfcomm-listen.service >/dev/null <<'UNIT'
[Unit]
Description=ClearFrame RFCOMM listener (channel 1)
After=cf-bt-setup.service
Requires=cf-bt-setup.service

[Service]
ExecStart=/usr/bin/rfcomm listen hci0 1
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now cf-rfcomm-listen.service
sudo reboot
# after reboot:
bluetoothctl show | egrep 'Alias|Name|Discoverable|Pairable'
systemctl status cf-rfcomm-listen.service
sudo apt update
sudo apt install -y bluez-tools
# Kill any previous agent
sudo pkill bt-agent || true
# Run a new one with a fixed PIN
sudo bt-agent -c DisplayYesNo -p /org/bluez -P 0000
sudo bluetoothctl
[bluetooth]# agent on
[bluetooth]# default-agent
[bluetooth]# pairable on
[bluetooth]# discoverable on
sudo apt install -y bluez-obexd
sudo apt install -y expect
#!/usr/bin/expect -f
spawn bluetoothctl
expect "#"
send "agent on\r"
expect "#"
send "default-agent\r"
expect "#"
interact {
}
#!/usr/bin/expect -f
spawn bluetoothctl
expect "#"
send "agent on\r"
expect "#"
send "default-agent\r"
expect "#"
interact {
}
# 1) Install expect
sudo apt update
sudo apt install -y expect
# 2) Create an expect agent that keeps bluetoothctl running and answers PIN with 0000
sudo tee /usr/local/bin/cf-bt-agent.expect >/dev/null <<'EOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl
# Set up as default agent + discoverable/pairable
expect -re {\[bluetooth\]#}
send "agent on\r"
expect -re {\[bluetooth\]#}
send "default-agent\r"
expect -re {\[bluetooth\]#}
send "pairable on\r"
expect -re {\[bluetooth\]#}
send "discoverable on\r"

# Sit and answer pairing prompts forever with PIN 0000
while {1} {
  expect {
    -re {Enter PIN code:}                { send "0000\r" }
    -re {Request passkey.*}              { send "0000\r" }
    -re {Confirm passkey .* \(yes/no\)}  { send "yes\r" }
    timeout { after 1000 }   ;# keep looping
    eof     { exit 0 }
  }
}
EOF

# 3) Make it executable and run it
sudo chmod +x /usr/local/bin/cf-bt-agent.expect
sudo /usr/local/bin/cf-bt-agent.expect
ps aux | grep [b]luetoothd
sudo systemctl daemon-reexec
sudo systemctl restart bluetooth
sudo hciconfig hci0 up piscan
sudo sdptool add SP
sudo bluetoothctl
[bluetooth]# agent KeyboardOnly
[bluetooth]# default-agent
[bluetooth]# pairable on
[bluetooth]# discoverable on
journalctl -u bluetooth -f
journalctl -u bluetooth -b --no-pager | tail -n 100
journalctl -u cf-bt-agent.service -b --no-pager | tail -n 50
bluetoothctl show
sudo bluetoothctl
[bluetooth]# paired-devices         # (optional: get old MACs)
[bluetooth]# remove 98:DA:92:01:0A:31   # replace with your Blade MAC if present
[bluetooth]# quit
sudo bluetoothctl
[bluetooth]# scan on
# wait until you see: Device 98:DA:92:01:0A:31 Blade
[bluetooth]# scan off
[bluetooth]# pair 98:DA:92:01:0A:31
# our agent should auto-answer the confirm
[bluetooth]# trust 98:DA:92:01:0A:31
[bluetooth]# quit
# bluetoothd must run in compat (-C) for SPP
ps aux | grep -E "[b]luetoothd"
# If you do NOT see "-C", run:
sudo systemctl edit bluetooth <<'EOT'
[Service]
ExecStart=
ExecStart=/usr/sbin/bluetoothd -C
EOT

sudo systemctl daemon-reexec
sudo systemctl restart bluetooth
# Keep discoverable/pairable persistent (no 3-minute timeout)
sudo bash -c 'grep -q "^\[General\]" /etc/bluetooth/main.conf || echo "[General]" >> /etc/bluetooth/main.conf'
sudo sed -i 's/^Name *=.*/Name = CF-RX/; t; $a Name = CF-RX' /etc/bluetooth/main.conf
sudo sed -i 's/^DiscoverableTimeout *=.*/DiscoverableTimeout = 0/; t; $a DiscoverableTimeout = 0' /etc/bluetooth/main.conf
sudo sed -i 's/^PairableTimeout *=.*/PairableTimeout = 0/; t; $a PairableTimeout = 0' /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
hciconfig hci0
sudo hciconfig hci0 up piscan
ps aux | grep [b]luetoothd
sudo bluetoothctl
[bluetooth]# power on
[bluetooth]# agent on
[bluetooth]# default-agent
[bluetooth]# system-alias CF-RX
[bluetooth]# discoverable on
[bluetooth]# pairable on
[bluetooth]# quit
sudo bluetoothctl
[bluetooth]# remove 98:DA:92:01:0A:31   # (your Blade MAC)
[bluetooth]# quit
sudo bluetoothctl
[bluetooth]# agent KeyboardOnly
[bluetooth]# default-agent
[bluetooth]# pairable on
[bluetooth]# discoverable on
sudo tee /usr/local/bin/cf-bt-agent.expect >/dev/null <<'EOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl
expect -re {\[bluetooth\]#}
send "agent KeyboardOnly\r"
expect -re {\[bluetooth\]#}
send "default-agent\r"
expect -re {\[bluetooth\]#}
send "pairable on\r"
expect -re {\[bluetooth\]#}
send "discoverable on\r"

while {1} {
  expect {
    -re {Enter PIN code:}                 { send "0000\r" }
    -re {Request passkey.*}               { send "0000\r" }
    -re {Confirm passkey .* \(yes/no\)}   { send "yes\r" }
    -re {Authorize service.* \(yes/no\)}  { send "yes\r" }
    timeout { after 1000 }
    eof     { exit 0 }
  }
}
EOF

sudo chmod +x /usr/local/bin/cf-bt-agent.expect
sudo systemctl restart cf-bt-agent.service
receiver@raspberrypi:~ $ sudo systemctl restart cf-bt-agent.service
Failed to restart cf-bt-agent.service: Unit cf-bt-agent.service not found.
sudo apt update
sudo apt install -y expect bluez bluez-tools
sudo tee /usr/local/bin/cf-bt-agent.expect >/dev/null <<'EOF'
#!/usr/bin/expect -f
set timeout -1
spawn bluetoothctl
expect -re {\[bluetooth\]#}
send "agent KeyboardOnly\r"
expect -re {\[bluetooth\]#}
send "default-agent\r"
expect -re {\[bluetooth\]#}
send "pairable on\r"
expect -re {\[bluetooth\]#}
send "discoverable on\r"

# Stay running and respond to pairing prompts
while {1} {
  expect {
    -re {Enter PIN code:}                 { send "0000\r" }
    -re {Request passkey.*}               { send "0000\r" }
    -re {Confirm passkey .* \(yes/no\)}   { send "yes\r" }
    -re {Authorize service.* \(yes/no\)}  { send "yes\r" }
    timeout { after 1000 }
    eof     { exit 0 }
  }
}
EOF

sudo chmod +x /usr/local/bin/cf-bt-agent.expect
# Add -C (compat) to bluetoothd via systemd override
sudo systemctl edit bluetooth
sudo systemctl daemon-reexec
sudo systemctl restart bluetooth
sudo hciconfig hci0 up piscan
sudo sdptool add SP || true
sudo tee /etc/systemd/system/cf-bt-agent.service >/dev/null <<'UNIT'
[Unit]
Description=ClearFrame Bluetooth PIN/Passkey Agent
After=bluetooth.service
Requires=bluetooth.service

[Service]
ExecStart=/usr/bin/expect /usr/local/bin/cf-bt-agent.expect
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now cf-bt-agent.service
systemctl status cf-bt-agent.service --no-pager
sudo bluetoothctl
[bluetooth]# remove 98:DA:92:01:0A:31     # Blade MAC if present; otherwise skip
[bluetooth]# quit
sudo tee /usr/local/bin/cf-bt-agent.expect >/dev/null <<'EOF'
#!/usr/bin/expect -f
# Auto-accept SSP Numeric Comparison ("Confirm passkey ... (yes/no)")
# Also handles legacy PIN prompts with 0000 if some device asks for it.
set timeout -1
spawn bluetoothctl
# Become the default agent with DisplayYesNo capability
expect -re {\[bluetooth\]#}
send "agent DisplayYesNo\r"
expect -re {\[bluetooth\]#}
send "default-agent\r"
# Stay pairable + discoverable
expect -re {\[bluetooth\]#}
send "pairable on\r"
expect -re {\[bluetooth\]#}
send "discoverable on\r"

# Loop forever, responding to prompts
while {1} {
  expect {
    -re {Confirm (passkey|Passkey).*?\(yes/no\)} { send "yes\r" }
    -re {Request confirmation.*?\(yes/no\)}      { send "yes\r" }
    -re {Authorize service.*?\(yes/no\)}         { send "yes\r" }
    -re {Enter PIN code:}                        { send "0000\r" }
    -re {Request passkey.*}                      { send "0000\r" }
    timeout { after 1000 }
    eof     { exit 0 }
  }
}
EOF

sudo chmod +x /usr/local/bin/cf-bt-agent.expect
sudo systemctl daemon-reload
sudo systemctl restart cf-bt-agent.service
systemctl status cf-bt-agent.service --no-pager
sudo rfcomm listen hci0 1
# expect: "Waiting for connection on channel 1"
# once your Blade app connects: "Connection from 98:DA:... to /dev/rfcomm0"
sudo rfcomm listen hci0 1
# expect: "Waiting for connection on channel 1"
# once your Blade app connects: "Connection from 98:DA:... to /dev/rfcomm0"
# 1) Stop any auto-listener we may have enabled earlier
sudo systemctl stop cf-rfcomm-listen.service 2>/dev/null
sudo systemctl disable cf-rfcomm-listen.service 2>/dev/null
# 2) Kill any stray rfcomm listener processes
sudo pkill -f "rfcomm listen" 2>/dev/null
# 3) Release any bound rfcomm devices/channels
sudo rfcomm -a                 # shows current bindings (e.g., rfcomm0)
# If you see rfcomm0 (or another number), release it:
sudo rfcomm release 0 2>/dev/null
# Also try releasing by controller/channel just in case:
sudo rfcomm release hci0 1 2>/dev/null
# 4) (Optional but safe) restart bluetooth to clear state
sudo systemctl restart bluetooth
# 5) Start a clean manual listener on channel 1
sudo rfcomm listen hci0 1
# bluetoothd must run in compat (-C) for SPP
ps aux | grep -E "[b]luetoothd"
# If you do NOT see "-C", run:
sudo systemctl edit bluetooth <<'EOT'
[Service]
ExecStart=
ExecStart=/usr/sbin/bluetoothd -C
EOT

sudo systemctl daemon-reexec
sudo systemctl restart bluetooth
# Keep discoverable/pairable persistent (no 3-minute timeout)
sudo bash -c 'grep -q "^\[General\]" /etc/bluetooth/main.conf || echo "[General]" >> /etc/bluetooth/main.conf'
sudo sed -i 's/^Name *=.*/Name = CF-RX/; t; $a Name = CF-RX' /etc/bluetooth/main.conf
sudo sed -i 's/^DiscoverableTimeout *=.*/DiscoverableTimeout = 0/; t; $a DiscoverableTimeout = 0' /etc/bluetooth/main.conf
sudo sed -i 's/^PairableTimeout *=.*/PairableTimeout = 0/; t; $a PairableTimeout = 0' /etc/bluetooth/main.conf
sudo systemctl restart bluetooth
