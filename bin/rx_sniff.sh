#!/usr/bin/env bash
set -euo pipefail
PORT=""
for p in /dev/ttyAMA0 /dev/serial0 /dev/ttyAMA1 /dev/ttyS0; do
  [ -e "$p" ] && PORT="$p" && break
done
[ -n "$PORT" ] || { echo "No UART port found"; exit 1; }
echo "[RX] sniffing $PORT for 15s..."
python - <<'PY'
import os, sys, time
CANDS=["/dev/ttyAMA0","/dev/serial0","/dev/ttyAMA1","/dev/ttyS0"]
port=next((p for p in CANDS if os.path.exists(p)), None)
assert port, "No UART"
import serial
ser=serial.Serial(port, baudrate=9600, timeout=0.05)
t0=time.time()
print(f"[RX] open {port}, reading...")
while time.time()-t0 < 15:
    b=ser.read(256)
    if b:
        hexs=" ".join(f"{x:02X}" for x in b)
        safe="".join(chr(x) if 32<=x<127 else "." for x in b)
        print(f"+{len(b):3d} | {hexs}\n     | {safe}")
print("[RX] sniff done.")
PY
