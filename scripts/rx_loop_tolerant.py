#!/usr/bin/env python3
"""
Robust/tolerant ClearFrame receiver loop.

Understands IDENT/LEN/SHA/DATA/DONE burst protocol from the transmitter.
- Gathers LoRa chunks (~220-240 bytes each) into a session buffer.
- Tracks expected LEN and SHA.
- Finalizes when:
    * DONE is seen (even if inline), OR
    * a new IDENT arrives (treat previous as done).
- Gives the radio 200ms grace to cough up tail bytes.
- Accepts frames that are "close enough" (>= ~90% LEN) and writes them anyway.
- Writes to /home/receiver/cfreceiver/data/incoming/vectors.bin
  which is what we feed to the Bluetooth SPP bridge for the glasses.
"""

import os, time, json, hashlib, pathlib
from clearframe.lora.io import LoRaLink
from clearframe.utils.settings import load_settings

CFG = load_settings()

WORK_DIR   = pathlib.Path("/home/receiver/cfreceiver/data/_rxwork")
FINAL_PATH = pathlib.Path("/home/receiver/cfreceiver/data/incoming/vectors.bin")
WORK_DIR.mkdir(parents=True, exist_ok=True)
FINAL_PATH.parent.mkdir(parents=True, exist_ok=True)

ident        = None
expect_len   = None
expect_sha   = None
data_buf     = bytearray()
ctrl_buf     = bytearray()

def reset_session():
    global ident, expect_len, expect_sha, data_buf, ctrl_buf
    ident = None
    expect_len = None
    expect_sha = None
    data_buf = bytearray()
    ctrl_buf = bytearray()

def try_lazy_finish(reason):
    """
    Called when we believe a frame is done (DONE or new IDENT).
    1. Sleep 200ms to allow UART/LoRa tail to finish spilling in.
    2. Check how complete we are.
    3. If good enough, write FINAL_PATH and report integrity.
    """
    global data_buf, expect_len, expect_sha

    time.sleep(0.2)

    data_bytes = bytes(data_buf)
    size_bytes = len(data_bytes)
    sha_local = hashlib.sha256(data_bytes).hexdigest()

    # require ~90% of expected length if we know it
    if expect_len is not None:
        min_ok = int(expect_len * 0.90)
    else:
        min_ok = 1

    good_size = (expect_len is None) or (size_bytes >= min_ok)
    len_exact = (expect_len is None) or (size_bytes == expect_len)
    sha_match = (expect_sha is None) or (sha_local == expect_sha)

    if not good_size:
        print(f"[CF-RX] ({reason}) finalize skipped: size {size_bytes}, expected {expect_len}, need >= {min_ok}")
        return False

    tmp_path = WORK_DIR / "vectors.bin"
    tmp_path.write_bytes(data_bytes)
    FINAL_PATH.write_bytes(data_bytes)

    print(f"[CF-RX] ({reason}) WROTE {FINAL_PATH} ({size_bytes} bytes)")
    print(f"[CF-RX] LEN exact? {len_exact} ({size_bytes} vs {expect_len})")
    print(f"[CF-RX] SHA match? {sha_match} (local {sha_local})")
    return True

def begin_new_frame(new_ident):
    """
    When a new IDENT= arrives:
    - finalize previous session (best-effort)
    - reset
    - start tracking new session with this ident
    """
    global ident
    if ident is not None:
        try_lazy_finish("new IDENT")
    reset_session()
    ident = new_ident
    print(f"[CF-RX] ident: {ident}")

def mark_len(val):
    global expect_len
    try:
        expect_len = int(val)
    except:
        expect_len = None
    print(f"[CF-RX] len: {expect_len}")

def mark_sha(val):
    global expect_sha
    expect_sha = val.lower()
    print(f"[CF-RX] sha: {expect_sha}")

def process_ctrl_text():
    """
    Read out any complete ASCII lines in ctrl_buf and handle IDENT/LEN/SHA etc.
    Also handles DONE if it appears as a full/partial line.
    """
    global ctrl_buf
    while b"\n" in ctrl_buf:
        line, _, rest = ctrl_buf.partition(b"\n")
        ctrl_buf = bytearray(rest)
        txt = line.decode("ascii","ignore").strip()

        if txt.startswith("IDENT="):
            begin_new_frame(txt.split("IDENT=",1)[1])
            continue

        if txt.startswith("LEN="):
            mark_len(txt.split("LEN=",1)[1])
            continue

        if txt.startswith("SHA="):
            mark_sha(txt.split("SHA=",1)[1])
            continue

        if "DONE" in txt:
            try_lazy_finish("DONE line")
            reset_session()
            continue

def scan_inline_done():
    """
    If 'DONE' shows up anywhere in ctrl_buf (glued inside a data chunk),
    finalize-and-reset.
    """
    global ctrl_buf
    if b"DONE" in ctrl_buf:
        try_lazy_finish("inline DONE")
        reset_session()
        idx = ctrl_buf.find(b"DONE")
        ctrl_buf = ctrl_buf[idx+4:]

def main():
    print("[CF-RX] receiver service (tolerant finalize)")
    link = LoRaLink(CFG)
    print("[CF-RX] radio open on /dev/ttyAMA0")
    print("[CF-RX] waiting for IDENT/LEN/SHA/DATA/DONE...")

    while True:
        chunk = link.recv_once(timeout_ms=500)
        if not chunk:
            continue

        # feed ctrl_buf first
        ctrl_buf.extend(chunk)

        # 1. detect inline DONE inside same chunk
        scan_inline_done()

        # 2. parse any complete lines for IDENT/LEN/SHA/DONE
        process_ctrl_text()

        # 3. payload accumulation for this ident
        if ident is not None:
            mostly_ascii = all((32 <= b <= 126) or b in (9,10,13) for b in chunk)
            if (not mostly_ascii) or (len(chunk) > 16):
                data_buf.extend(chunk)
                print(f"[CF-RX] +{len(chunk)} bytes (total {len(data_buf)})")

if __name__ == "__main__":
    reset_session()
    main()
