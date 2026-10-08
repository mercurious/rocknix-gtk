#!/usr/bin/env python3
"""bootimg_parity.py — the ABL-era KERNEL parity gate (K2, UPSTREAM_20261001.md).

Under ROCKNIX's qcom-abl boot (20261001+), /flash/KERNEL is an Android boot.img
v0: gzip'd arm64 Image with the device DTBs appended, a 5-byte "dummy" ramdisk
(the initramfs is built into the Image), and the cmdline baked into the header —
the ABL appends nothing, so anything ETK needs on the cmdline must be in here.
Upstream recipe: projects/ROCKNIX/packages/linux/package.mk (makeinstall_target).

  fields REF                 print the reference's header values as shell vars
                             (build_72.sh feeds mkbootimg from stock, not constants)
  check  REF CAND --extra S  CAND must equal REF in every field that matters,
                             with cmdline == REF cmdline + " " + S exactly, and every
                             DTB byte-identical to stock -- EXCEPT the kit DTBs:
         --kit-models "A|B"  root models whose DTB carries the ETK kit splice (mic,
                             USB-C VBUS: etk_dtb_mic.py). Those MUST differ from stock
                             and, with --kit-check <etk_dtb_mic.py>, must report
                             DTB_MIC_PATCHED. A kit model found byte-identical, or a
                             non-kit model found different, is a PARITY FAIL.
  show   IMG                 human summary of one image

Exit 0 = parity, 1 = a mismatch (each printed as PARITY FAIL), 2 = unreadable.
"""
import struct, sys, zlib, shlex

HDR = struct.Struct('<8s10I16s512s32s1024s')


def die(msg):
    print(f'bootimg_parity: {msg}', file=sys.stderr)
    sys.exit(2)


def parse_fdt_root(b):
    """Root-node 'model' and 'compatible' of one flattened device tree."""
    _, total, off_struct, off_strings = struct.unpack_from('>4I', b, 0)
    strings = b[off_strings:]
    p, depth, props = off_struct, 0, {}
    while p < total:
        tok = struct.unpack_from('>I', b, p)[0]; p += 4
        if tok == 1:                                   # BEGIN_NODE
            end = b.index(b'\0', p); p = (end + 4) & ~3; depth += 1
        elif tok == 2:                                 # END_NODE
            depth -= 1
            if depth == 0:
                break
        elif tok == 3:                                 # PROP
            ln, nameoff = struct.unpack_from('>II', b, p); p += 8
            name = strings[nameoff:strings.index(b'\0', nameoff)].decode()
            if depth == 1 and name in ('model', 'compatible'):
                props[name] = b[p:p + ln].rstrip(b'\0').replace(b'\0', b' ').decode(errors='replace')
            p = (p + ln + 3) & ~3
        elif tok in (4,):                              # NOP
            continue
        else:                                          # END or junk
            break
    return props.get('model', ''), props.get('compatible', '')


def load(path):
    try:
        data = open(path, 'rb').read()
    except OSError as e:
        die(f'cannot read {path}: {e}')
    if len(data) < HDR.size or data[:8] != b'ANDROID!':
        die(f'{path}: not an Android boot image')
    f = HDR.unpack_from(data, 0)
    h = dict(kernel_size=f[1], kernel_addr=f[2], ramdisk_size=f[3], ramdisk_addr=f[4],
             second_size=f[5], second_addr=f[6], tags_addr=f[7], page_size=f[8],
             header_version=f[9], os_version=f[10],
             name=f[11].rstrip(b'\0'), cmdline=f[12].rstrip(b'\0').decode(),
             extra_cmdline=f[14].rstrip(b'\0').decode())
    ps = h['page_size']
    if ps not in (2048, 4096, 16384):
        die(f'{path}: implausible page size {ps}')
    koff = ps
    kern = data[koff:koff + h['kernel_size']]
    roff = koff + ((h['kernel_size'] + ps - 1) // ps) * ps
    h['ramdisk'] = data[roff:roff + h['ramdisk_size']]
    d = zlib.decompressobj(31)                         # gzip
    try:
        image = d.decompress(kern)
    except zlib.error as e:
        die(f'{path}: kernel payload is not gzip: {e}')
    if not d.eof:
        die(f'{path}: gzip stream truncated')
    tail = d.unused_data
    dtbs, p = [], 0
    while p + 8 <= len(tail):
        magic, total = struct.unpack_from('>II', tail, p)
        if magic != 0xd00dfeed or total < 40 or p + total > len(tail):
            break
        blob = tail[p:p + total]
        dtbs.append((blob,) + parse_fdt_root(blob))
        p += total
    h['trailing_junk'] = len(tail) - p
    h['dtbs'] = dtbs
    h['image'] = image
    lv = image.find(b'Linux version ')
    h['linux_version'] = image[lv:image.index(b'\n', lv)].decode(errors='replace') if lv >= 0 else ''
    h['arm64'] = image[0x38:0x3c] == b'ARM\x64'
    return h


def os_fields(osv):
    """Decode the packed os_version word into mkbootimg's two string args."""
    ver, lvl = osv >> 11, osv & 0x7ff
    a, b, c = (ver >> 14) & 0x7f, (ver >> 7) & 0x7f, ver & 0x7f
    y, m = (lvl >> 4) + 2000, lvl & 0xf
    return f'{a}.{b}.{c}', f'{y:04d}-{m:02d}'


def cmd_fields(ref):
    h = load(ref)
    v, lvl = os_fields(h['os_version'])
    out = dict(REF_OS_VERSION=v, REF_OS_PATCH=lvl, REF_PAGESIZE=h['page_size'],
               REF_BASE=f"0x{h['kernel_addr']:08x}",
               REF_RAMDISK_OFFSET=f"0x{h['ramdisk_addr'] - h['kernel_addr']:08x}",
               REF_TAGS_OFFSET=f"0x{h['tags_addr'] - h['kernel_addr']:08x}",
               REF_CMDLINE=h['cmdline'], REF_DTB_COUNT=len(h['dtbs']))
    for k, val in out.items():
        print(f'{k}={shlex.quote(str(val))}')


def cmd_show(img):
    h = load(img)
    v, lvl = os_fields(h['os_version'])
    print(f"{img}: header v{h['header_version']} page {h['page_size']} base 0x{h['kernel_addr']:08x} os {v} patch {lvl}")
    print(f"  cmdline: {h['cmdline']}")
    print(f"  ramdisk: {h['ramdisk_size']} B {h['ramdisk'][:16]!r}")
    print(f"  kernel : {h['linux_version'] or '(no Linux version string)'} arm64={h['arm64']}")
    for i, (_, model, _c) in enumerate(h['dtbs']):
        print(f'  dtb[{i}]: {model}')
    if h['trailing_junk']:
        print(f"  WARNING: {h['trailing_junk']} trailing bytes after the last DTB")


def kit_check(tool, blob):
    """etk_dtb_mic.py check <blob> -> 'PATCHED' | 'STOCK' | 'FAIL <why>'."""
    import subprocess, tempfile, os
    fd, path = tempfile.mkstemp(suffix='.dtb'); os.write(fd, blob); os.close(fd)
    try:
        out = subprocess.run([sys.executable, '-I', tool, 'check', path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    txt = (out.stdout + out.stderr).strip()
    if 'DTB_MIC_PATCHED' in txt: return 'PATCHED'
    if 'DTB_MIC_STOCK' in txt: return 'STOCK'
    return 'FAIL ' + txt.splitlines()[-1] if txt else 'FAIL (no output)'


def cmd_check(ref, cand, extra, kit_models=(), kit_tool=None):
    r, c = load(ref), load(cand)
    fails, notes = [], []
    def same(key, label=None):
        if r[key] != c[key]:
            fails.append(f'{label or key}: ref {r[key]!r} != cand {c[key]!r}')
    for k in ('header_version', 'page_size', 'kernel_addr', 'ramdisk_addr', 'tags_addr',
              'os_version', 'name', 'extra_cmdline', 'second_size'):
        same(k)
    if r['second_size'] and c['second_size']:
        same('second_addr')
    if r['ramdisk'] != c['ramdisk']:
        fails.append(f"ramdisk: ref {r['ramdisk'][:16]!r} != cand {c['ramdisk'][:16]!r}")
    want = (r['cmdline'] + ' ' + extra).strip() if extra else r['cmdline']
    if c['cmdline'] != want:
        fails.append(f"cmdline: want {want!r}\n                    got  {c['cmdline']!r}")
    if not c['arm64']:
        fails.append('kernel: decompressed payload is not an arm64 Image (no ARM\\x64 magic)')
    if c['trailing_junk']:
        fails.append(f"kernel: {c['trailing_junk']} trailing bytes after the last DTB")
    rm = [(m, comp) for _, m, comp in r['dtbs']]
    cm = [(m, comp) for _, m, comp in c['dtbs']]
    if rm != cm:
        fails.append('dtbs: model/compatible list or ORDER differs (the ABL picks by this list)\n'
                     + '\n'.join(f'      ref[{i}] {m}' for i, (m, _) in enumerate(rm)) + '\n'
                     + '\n'.join(f'      cand[{i}] {m}' for i, (m, _) in enumerate(cm)))
    else:
        # STRICT (2026-10-08): with DTC_FLAGS=-@ the recipe reproduces stock's DTBs
        # byte-for-byte, so any non-kit difference is a real drift -> FAIL. Kit DTBs
        # (the models named) must differ AND verify as patched by the splicer.
        ident, kit = 0, []
        for (a, am, _ac), (b, _bm, _bc) in zip(r['dtbs'], c['dtbs']):
            if am in kit_models:
                if a == b:
                    fails.append(f'dtbs: kit model "{am}" is byte-identical to stock (the kit splice did not happen)')
                    continue
                verdict = kit_check(kit_tool, b) if kit_tool else 'unverified'
                if verdict not in ('PATCHED', 'unverified'):
                    fails.append(f'dtbs: kit model "{am}" differs from stock but is not a kit DTB: {verdict}')
                kit.append(f'{am} [{verdict}]')
            elif a == b:
                ident += 1
            else:
                fails.append(f'dtbs: "{am}" differs from stock and is not a kit model (source/dtc drift)')
        notes.append(f'dtbs: {len(cm)} in stock order; {ident}/{len(cm) - len(kit_models)} non-kit byte-identical to stock'
                     + (f'; kit: {", ".join(kit)}' if kit else ''))
    notes.append(f"kernel: {c['linux_version']}")
    for n in notes:
        print(f'PARITY NOTE: {n}')
    for f in fails:
        print(f'PARITY FAIL: {f}')
    if fails:
        return 1
    print(f"PARITY OK: {cand} matches {ref} (header, ramdisk, DTB order) with cmdline + {extra!r}")
    return 0


def main(argv):
    if len(argv) >= 3 and argv[1] == 'fields':
        cmd_fields(argv[2]); return 0
    if len(argv) >= 3 and argv[1] == 'show':
        cmd_show(argv[2]); return 0
    if len(argv) >= 4 and argv[1] == 'check':
        def opt(name, default=''):
            if name in argv:
                i = argv.index(name)
                return argv[i + 1] if i + 1 < len(argv) else die(f'{name} needs a value')
            return default
        extra = opt('--extra')
        kit_models = tuple(m for m in opt('--kit-models').split('|') if m)
        kit_tool = opt('--kit-check') or None
        return cmd_check(argv[2], argv[3], extra, kit_models, kit_tool)
    print(__doc__.strip())
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
