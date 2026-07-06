#!/usr/bin/env python3
"""Extract the embedded gzip'd initramfs cpio from an uncompressed arm64 kernel Image.

Scans for gzip magic (1f 8b 08), attempts streaming decompression at each hit,
and keeps candidates whose payload is a newc cpio archive ("070701").
Usage: extract_initramfs.py <KERNEL-image> <out.cpio>
"""
import sys
import zlib

def main():
    image_path, out_path = sys.argv[1], sys.argv[2]
    data = open(image_path, "rb").read()
    print(f"image: {len(data)} bytes")

    candidates = []
    pos = 0
    while True:
        pos = data.find(b"\x1f\x8b\x08", pos)
        if pos == -1:
            break
        d = zlib.decompressobj(wbits=47)
        out = bytearray()
        try:
            # decompress in chunks so one bad hit doesn't cost the world
            i = pos
            while i < len(data) and not d.eof:
                out += d.decompress(data[i:i + 1 << 20])
                i += 1 << 20
            if out[:6] == b"070701":
                candidates.append((pos, bytes(out)))
                print(f"  offset {pos:#x}: cpio candidate, {len(out)} bytes decompressed")
            elif len(out) > 1 << 20:
                print(f"  offset {pos:#x}: gzip stream but not cpio ({len(out)} bytes, head={bytes(out[:8])!r})")
        except Exception:
            pass
        pos += 3

    if not candidates:
        print("NO initramfs cpio found")
        sys.exit(1)

    off, cpio = max(candidates, key=lambda c: len(c[1]))
    trailer = cpio.rfind(b"TRAILER!!!")
    nfiles = cpio.count(b"070701")
    print(f"selected offset {off:#x}: {len(cpio)} bytes, {nfiles} cpio headers, TRAILER at {trailer}")
    with open(out_path, "wb") as f:
        f.write(cpio)
    print(f"wrote {out_path}")

if __name__ == "__main__":
    main()
