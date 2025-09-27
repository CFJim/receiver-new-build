import time, pathlib
from clearframe.utils.settings import load_settings
from clearframe.lora.io import LoRaLink
from clearframe.codec.pipe import maybe_compress, maybe_encrypt, maybe_decrypt, maybe_decompress
from clearframe.ble.bridge import send_to_glasses_simple

def chunker(b,n):
    for i in range(0,len(b),n): yield b[i:i+n]

def run_tx(cfg):
    ident=cfg["identification"]["tx_serial"].encode("ascii")
    path=pathlib.Path(cfg["paths"]["outgoing_bin"])
    data=path.read_bytes() if path.exists() else b""
    profile=cfg["mode"]["profile"]
    payload=maybe_encrypt(maybe_compress(data,profile),profile)
    completion=cfg["transport"]["completion_key"].encode("ascii")
    pkt=int(cfg["transport"]["packet_size_bytes"])
    inter=int(cfg["transport"]["inter_packet_ms"])
    link=LoRaLink(cfg)
    print("[TX] ident:",ident.decode()); link.send_chunks([ident],inter)
    print("[TX] payload bytes:",len(payload)); link.send_chunks(chunker(payload,pkt),inter)
    time.sleep(0.05); print("[TX] completion"); link.send_chunks([completion],inter); print("[TX] done.")

def run_rx(cfg):
    profile=cfg["mode"]["profile"]; ident=None
    out=pathlib.Path(cfg["paths"]["incoming_bin"])
    link=LoRaLink(cfg); buf=bytearray()
    completion=cfg["transport"]["completion_key"].encode("ascii")
    print("[RX] listening…")
    while True:
        b=link.recv_once(timeout_ms=500)
        if not b: continue
        s=b.decode("ascii",errors="ignore")
        if ident is None and s.startswith(cfg["identification"]["tx_serial"]):
            ident=s; print("[RX] ident:",ident)
            if cfg["mode"]["profile"]=="testing": buf.clear()
        elif b==completion:
            print("[RX] completion")
            data=maybe_decompress(maybe_decrypt(bytes(buf),profile),profile)
            out.parent.mkdir(parents=True,exist_ok=True)
            if out.exists(): out.unlink()
            out.write_bytes(data); print(f"[RX] wrote {out} ({len(data)} bytes)")
            try: send_to_glasses_simple(b"",b"")
            except Exception as e: print("[RX] BLE placeholder:",e)
            ident=None; buf.clear()
        else:
            if ident is not None: buf.extend(b)

def main():
    cfg=load_settings(); role=cfg["mode"]["role"]
    if role=="transmitter": run_tx(cfg)
    elif role=="receiver": run_rx(cfg)
    else: raise SystemExit("Unknown role")
if __name__=="__main__": main()
