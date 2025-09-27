set -euo pipefail

# ---------- 1) UART: enable + map PL011 to GPIO (BT -> mini-UART) ----------
CFG=/boot/firmware/config.txt; [ -f /boot/config.txt ] && CFG=/boot/config.txt
CMD=/boot/firmware/cmdline.txt;  [ -f /boot/cmdline.txt ]  && CMD=/boot/cmdline.txt

sudo cp -n "$CFG" "${CFG}.bak" || true
sudo cp -n "$CMD" "${CMD}.bak" || true

sudo sed -i '/^[[:space:]]*enable_uart=/d; /^[[:space:]]*dtoverlay=disable-bt/d; /^[[:space:]]*dtoverlay=miniuart-bt/d' "$CFG"
echo "enable_uart=1"         | sudo tee -a "$CFG" >/dev/null
echo "dtoverlay=miniuart-bt" | sudo tee -a "$CFG" >/dev/null

sudo sed -i -E 's/(^| )console=(serial0|ttyAMA0|ttyAMA1|ttyS0),[0-9]+( |$)/ /g' "$CMD"

sudo systemctl disable --now serial-getty@ttyAMA0.service serial-getty@ttyS0.service hciuart.service bluetooth.service 2>/dev/null || true
sudo usermod -aG dialout,spi,gpio "$USER" || true

# ---------- 2) Make sure project skeleton exists ----------
cd ~/clearframe
mkdir -p clearframe/{lora,utils,vendor/waveshare/hat_uart} config logs

[ -f clearframe/utils/settings.py ] || cat > clearframe/utils/settings.py <<'PY'
import json, pathlib
def load_settings(path='config/settings.json'):
    p=pathlib.Path(path); return json.load(p.open())
PY

cat > bin/run_clearframe.sh <<'RUN'
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
mkdir -p logs
[ -f .venv/bin/activate ] && . .venv/bin/activate
python app.py 2>&1 | tee -a logs/clearframe.log
RUN
chmod +x bin/run_clearframe.sh

# ---------- 3) Vendor Waveshare UART driver ----------
sudo apt-get update -y
sudo apt-get install -y unzip wget python3-serial
wget -O /tmp/SX126X_LoRa_HAT_CODE.zip "https://files.waveshare.com/upload/1/18/SX126X_LoRa_HAT_CODE.zip"
rm -rf /tmp/SX126X_LoRa_HAT_Code; mkdir -p /tmp/SX126X_LoRa_HAT_Code
unzip -q /tmp/SX126X_LoRa_HAT_CODE.zip -d /tmp/SX126X_LoRa_HAT_Code
cp -f "$(find /tmp/SX126X_LoRa_HAT_Code -iname sx126x.py | head -n1)" clearframe/vendor/waveshare/hat_uart/
touch clearframe/vendor/waveshare/__init__.py clearframe/vendor/waveshare/hat_uart/__init__.py

# ---------- 4) UART-based LoRa wrapper ----------
cat > clearframe/lora/io.py <<'PY'
import os, time, sys, pathlib
from clearframe.utils.settings import load_settings

SX_MOD=None
try:
    import sx126x as SX_MOD
except Exception:
    try:
        vendor = pathlib.Path(__file__).resolve().parents[1] / "vendor" / "waveshare" / "hat_uart"
        sys.path.insert(0, str(vendor))
        import sx126x as SX_MOD  # type: ignore
    except Exception as e:
        SX_MOD=None
        _import_err=e

PORT_CANDIDATES=["/dev/ttyAMA0","/dev/ttyAMA1","/dev/serial0","/dev/ttyS0"]

def _pick_port():
    for p in PORT_CANDIDATES:
        if os.path.exists(p):
            return p
    return None

class LoRaLink:
    def __init__(self, cfg=None):
        self.cfg = cfg or load_settings()
        self.ser = None
        self.node = None
        port = _pick_port()
        if not port:
            raise RuntimeError(f"No UART device found among {PORT_CANDIDATES}")
        freq_mhz = int(round(self.cfg["lora"]["frequency_hz"] / 1_000_000))
        print(f"[LoRa] using port: {port}")

        if SX_MOD is not None:
            self.node = SX_MOD.sx126x(
                serial_num=port, freq=freq_mhz, addr=0,
                power=min(22, int(self.cfg["lora"]["tx_power_dbm"])),
                rssi=False, air_speed=2400, relay=False
            )
            self.ser = self.node.ser
        else:
            import serial
            self.ser = serial.Serial(port, baudrate=115200, timeout=0.1)
        time.sleep(0.05)

    def send_chunks(self, chunks, inter_ms=20):
        for c in chunks:
            self.ser.write(bytes(c)); self.ser.flush(); time.sleep(inter_ms/1000.0)

    def recv_once(self, maxlen=255, timeout_ms=500):
        t0=time.time(); buf=bytearray()
        while (time.time()-t0)*1000<timeout_ms:
            n=getattr(self.ser,"in_waiting",0)
            if n:
                buf.extend(self.ser.read(min(n, maxlen-len(buf))))
                if len(buf)>=maxlen: break
            else:
                time.sleep(0.01)
        return bytes(buf)
PY

# ---------- 5) Ensure role=receiver (or create default file) ----------
if [ -f config/settings.json ]; then
  sed -i -E 's/"role"[[:space:]]*:[[:space:]]*"[^"]+"/"role":"receiver"/' config/settings.json
else
  cat > config/settings.json <<'JSON'
{
  "project": "clearframe",
  "mode": { "role": "receiver", "profile": "testing" },
  "lora": { "region":"US915","frequency_hz":915000000,"bandwidth_khz":125,"spreading_factor":7,"coding_rate":"4/5","preamble_len":8,"sync_word":52,"tx_power_dbm":14,
    "pins": { "spi_bus":0,"spi_cs":0,"busy":4,"dio1":16,"reset":18,"txen":6,"rxen":-1 } },
  "identification": { "tx_serial": "CFTX25000001" },
  "paths": { "outgoing_bin": "data/outgoing/vectors.bin", "incoming_bin": "data/incoming/vectors.bin" },
  "transport": { "packet_size_bytes": 200, "inter_packet_ms": 20, "completion_key": "CF_DONE" },
  "features": { "compression": { "enabled_in_operational": true, "algorithm": "lz4", "level": 0 },
                "encryption": { "enabled_in_operational": true, "cipher": "aes-256-gcm", "keyfile": "config/keys/tx.key" },
                "bluetooth": { "enabled_on_receiver": true, "target_device_name": "SmartGlasses", "mtu": 180 } }
}
JSON
fi

echo ">>> Receiver setup complete. Rebooting to apply UART changes..."
sudo reboot
