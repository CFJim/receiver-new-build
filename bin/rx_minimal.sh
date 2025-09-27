#!/usr/bin/env bash
set -euo pipefail
cd ~/clearframe
python - <<'PY'
from clearframe.lora.io import LoRaLink
from clearframe.utils.settings import load_settings
cfg=load_settings()
l=LoRaLink(cfg)
print("[RX] port:", getattr(l.ser,"port","?"))
buf=bytearray()
print("[RX] printing newline-delimited frames…  (Ctrl+C to exit)")
while True:
    b=l.recv_once(512, 800)
    if not b: 
        continue
    buf += b
    while b'\n' in buf:
        line, _, buf = buf.partition(b'\n')
        try: s = line.decode('utf-8','ignore')
        except: s = str(line)
        print(f"[RX] {s}")
PY
