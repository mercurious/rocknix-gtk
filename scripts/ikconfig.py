#!/usr/bin/env python3
"""ikconfig.py — `extract-ikconfig` for a kernel we have not extracted yet.

The kernel tree ships scripts/extract-ikconfig, but stage_72.sh needs the stock
config BEFORE the tarball is unpacked, and on the BLS lane (ROCKNIX 20261101+) the
config ground truth is carved from the stock /flash/KERNEL itself (a raw PE Image
with CONFIG_IKCONFIG=y) instead of pulled from a migrated rig's /proc/config.gz.
Same algorithm as the kernel's script: the bytes between IKCFG_ST and IKCFG_ED are
a gzip stream of the .config.

Accepts the raw arm64 Image (MZ + ARMd at 0x38), a gzip'd Image, or an Android
boot.img v0 (the 20261001 format: gzip'd Image + DTBs in the kernel blob), so one
tool reads every format this fork has shipped against.

    ikconfig.py <KERNEL> <out.config>        exit 0, prints offsets + line count
                                             exit 1: no IKCFG markers (IKCONFIG off,
                                             or a compressed image this tool cannot
                                             unwrap)
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


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-6].strip(), file=sys.stderr)
        return 2
    data = open(argv[1], "rb").read()
    img, how = unwrap(data)
    pe = img[:2] == b"MZ" and img[0x38:0x3c] == b"ARMd"
    st = img.find(b"IKCFG_ST")
    ed = img.find(b"IKCFG_ED", st) if st >= 0 else -1
    if st < 0 or ed < 0:
        print(f"ikconfig: no IKCFG markers in {argv[1]} ({how}; arm64 Image: {'yes' if pe else 'NO'})",
              file=sys.stderr)
        return 1
    blob = img[st + 8:ed]
    cfg = zlib.decompress(blob, wbits=47)
    with open(argv[2], "wb") as f:
        f.write(cfg)
    print(f"ikconfig: {how}; IKCFG_ST at {st:#x}, IKCFG_ED at {ed:#x}, gz {len(blob)} B -> "
          f"{len(cfg)} B, {cfg.count(b'\n')} lines -> {argv[2]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
