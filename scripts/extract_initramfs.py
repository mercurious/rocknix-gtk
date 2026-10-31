#!/usr/bin/env python3
"""Extract the embedded gzip'd initramfs cpio from an arm64 kernel Image.

Scans for gzip magic (1f 8b 08), attempts streaming decompression at each hit,
and keeps candidates whose payload is a newc cpio archive ("070701").

One carver, every format this fork has shipped against (2026-10-31):
  * raw arm64 Image (GRUB era 20260901, BLS era 20261101+: the PE /flash/KERNEL) --
    scanned as is; the cpio is a gzip stream inside the uncompressed Image;
  * gzip'd Image -- inflated first;
  * Android boot.img v0 (qcom-abl era 20261001) -- the kernel blob is located via the
    header (page-aligned after it) and inflated first; the appended DTBs are ignored.
  Without the unwrap a boot.img's inner cpio sits INSIDE the outer gzip stream and the
  scan cannot see it (it only inflates the outer stream, which is not a cpio).
Usage: extract_initramfs.py <KERNEL> <out.cpio>
"""
import struct
import sys
import zlib


def inflate_all(buf, start):
    d = zlib.decompressobj(wbits=47)
    out = bytearray()
    i = start
    while i < len(buf) and not d.eof:
        out += d.decompress(buf[i:i + (1 << 20)])
        i += 1 << 20
    return bytes(out)


def unwrap(data):
    """-> (uncompressed arm64 Image bytes, how)."""
    if data[:8] == b"ANDROID!":
        ksz, _ka, _rs, _ra, _ss, _sa, _tags, psz = struct.unpack_from("<8I", data, 8)
        k = data[psz:psz + ksz]
        if k[:3] == b"\x1f\x8b\x08":
            return inflate_all(k, 0), f"boot.img v0, gzip kernel {ksz} B"
        return k, f"boot.img v0, raw kernel {ksz} B"
    if data[:3] == b"\x1f\x8b\x08":
        return inflate_all(data, 0), "gzip Image"
    return data, "raw Image"


def main():
    image_path, out_path = sys.argv[1], sys.argv[2]
    data, how = unwrap(open(image_path, "rb").read())
    pe = data[:2] == b"MZ" and data[0x38:0x3c] == b"ARMd"
    print(f"image: {len(data)} bytes ({how}; arm64 PE Image: {'yes' if pe else 'NO'})")

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
