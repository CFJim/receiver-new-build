#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
CLEARFRAME_FORCE_RAW=1 python - <<'PY'
from clearframe.lora.io import LoRaLink
from clearframe.utils.settings import load_settings
cfg=load_settings()
l=LoRaLink(cfg)
print("[RX] RAW port:", getattr(l.ser,"port","?"), "baud=9600")
buf=bytearray()
print("[RX] printing newline-delimited frames…  (Ctrl+C to exit)")
while True:
    b=l.recv_once(512, 1000)
    if not b: 
        continue
    buf += b
    while b'\n' in buf:
        line, _, buf = buf.partition(b'\n')
        try: s=line.decode('utf-8','ignore')
        except Exception: s=str(line)
        print(f"[RX] {s}")
PY
