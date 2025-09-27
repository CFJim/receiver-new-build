import os, time, sys, pathlib
from clearframe.utils.settings import load_settings

# Try system module first, then vendored copy; can be bypassed by env
SX_MOD = None
_import_err = None
if os.environ.get("CLEARFRAME_FORCE_RAW") != "1":
    try:
        import sx126x as SX_MOD
    except Exception as e1:
        try:
            vendor = pathlib.Path(__file__).resolve().parents[1] / "vendor" / "waveshare" / "hat_uart"
            sys.path.insert(0, str(vendor))
            import sx126x as SX_MOD  # type: ignore
        except Exception as e2:
            SX_MOD = None
            _import_err = e2

PORT_CANDIDATES = ["/dev/ttyAMA0", "/dev/ttyAMA1", "/dev/serial0", "/dev/ttyS0"]

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
        print(f"[LoRa] using port: {port}")

        # Valid power steps for Waveshare HAT
        allowed = [10, 13, 17, 22]
        cfgp = int(self.cfg.get("lora", {}).get("tx_power_dbm", 22))
        power_dbm = min(allowed, key=lambda v: abs(v - cfgp))

        # If driver available and not forced raw, try it; else raw UART at 9600
        if SX_MOD is not None:
            try:
                self.node = SX_MOD.sx126x(
                    serial_num=port,
                    freq=int(round(self.cfg["lora"]["frequency_hz"] / 1_000_000)),
                    addr=0,
                    power=power_dbm,
                    rssi=False,
                    air_speed=2400,
                    net_id=int(self.cfg["lora"].get("net_id", 0)),
                    buffer_size=240,
                    crypt=0,
                    relay=False,
                    lbt=False,
                    wor=False
                )
                self.ser = self.node.ser
            except Exception as e:
                print(f"[LoRa] Waveshare driver failed ({e}); falling back to raw UART")
                import serial
                self.ser = serial.Serial(port, baudrate=9600, timeout=0.1, exclusive=True)
                self.ser.reset_input_buffer(); self.ser.reset_output_buffer(); time.sleep(0.05)
        else:
            import serial
            self.ser = serial.Serial(port, baudrate=9600, timeout=0.1)
            time.sleep(0.05)

    def send_chunks(self, chunks, inter_ms=20):
        for c in chunks:
            self.ser.write(bytes(c)); self.ser.flush(); time.sleep(inter_ms/1000.0)

    def recv_once(self, maxlen=255, timeout_ms=500):
        t0 = time.time(); buf = bytearray()
        while (time.time() - t0) * 1000 < timeout_ms:
            n = getattr(self.ser, "in_waiting", 0)
            if n:
                buf.extend(self.ser.read(min(n, maxlen - len(buf))))
                if len(buf) >= maxlen: break
            else:
                time.sleep(0.01)
        return bytes(buf)
