import time, sys, pathlib
from clearframe.utils.settings import load_settings

SX_MOD = None
_import_error = None
try:
    # Try system-wide first
    import sx126x as SX_MOD  # type: ignore
except Exception as e1:
    try:
        # Then vendored copy
        vendor = pathlib.Path(__file__).resolve().parents[1] / "vendor" / "waveshare" / "hat_uart"
        sys.path.insert(0, str(vendor))
        import sx126x as SX_MOD  # type: ignore
    except Exception as e2:
        _import_error = e2
        SX_MOD = None

class LoRaLink:
    def __init__(self, cfg=None):
        self.cfg = cfg or load_settings()
        self.ser = None
        self.node = None
        freq_mhz = int(round(self.cfg["lora"]["frequency_hz"] / 1_000_000))
        # Prefer Waveshare driver to set radio params; otherwise use transparent UART
        if SX_MOD is not None:
            self.node = SX_MOD.sx126x(
                serial_num="/dev/ttyS0",
                freq=freq_mhz,
                addr=0,
                power=min(22, int(self.cfg["lora"]["tx_power_dbm"])),
                rssi=False,
                air_speed=2400,
                relay=False
            )
            # Driver exposes underlying pyserial handle as .ser
            self.ser = self.node.ser
        else:
            try:
                import serial  # pyserial
            except Exception as e:
                raise RuntimeError(f"LoRa driver import failed ({_import_error}); and pyserial missing: {e}")
            try:
                self.ser = serial.Serial("/dev/ttyS0", 9600, timeout=0.1)
            except Exception as e:
                raise RuntimeError(f"Cannot open /dev/ttyS0: {e}")

    def send_chunks(self, chunks, inter_ms=20):
        for c in chunks:
            self.ser.write(bytes(c))
            self.ser.flush()
            time.sleep(inter_ms/1000.0)

    def recv_once(self, maxlen=255, timeout_ms=500):
        t0 = time.time()
        buf = bytearray()
        while (time.time() - t0) * 1000 < timeout_ms:
            n = self.ser.in_waiting if hasattr(self.ser, "in_waiting") else 0
            if n:
                buf.extend(self.ser.read(min(n, maxlen - len(buf))))
                if len(buf) >= maxlen:
                    break
            else:
                time.sleep(0.01)
        return bytes(buf)
