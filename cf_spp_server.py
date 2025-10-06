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
