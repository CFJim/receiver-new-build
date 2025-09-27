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
