"""Extract the 4x6 'Terminal' cell font from a Windows .FON file.

The original game asked the OS for a 4x6 console face (`GR_initFont`,
origRef/Renderer/gam_render.c) and rendered every one of the 240x120 cells with it.
That face lives in `dosapp.fon` (and its codepage siblings app850/852/855/857/866,
app775, dos737 -- all byte-identical over ASCII 0x20-0x7E).

A .FON is a 16-bit NE executable whose RT_FONT resources are FNT font structures.

Usage:
    python3 extract_cellfont.py <dir-of-fon-files> [width height]   # enumerate faces
    python3 extract_cellfont.py --emit <dosapp.fon> <out.bin>       # write the atlas

The emitted atlas is 1536 bytes: 256 glyphs x 6 rows, one byte per row, bit 7 =
leftmost pixel (low nibble unused).
"""
import struct, sys, os

RT_FONT = 0x8008


def u8(d, o):  return d[o]
def u16(d, o): return struct.unpack_from('<H', d, o)[0]
def u32(d, o): return struct.unpack_from('<I', d, o)[0]


def ne_font_resources(data):
    """Yield (offset, length) of each RT_FONT resource in an NE executable."""
    if data[:2] != b'MZ':
        return
    ne_off = u32(data, 0x3C)
    if ne_off + 2 > len(data) or data[ne_off:ne_off + 2] != b'NE':
        return
    rsrc = ne_off + u16(data, ne_off + 0x24)
    shift = u16(data, rsrc)
    p = rsrc + 2
    while True:
        type_id = u16(data, p)
        if type_id == 0:
            break
        count = u16(data, p + 2)
        p += 8
        for _ in range(count):
            off, length = u16(data, p), u16(data, p + 2)
            if type_id == RT_FONT:
                yield (off << shift, length << shift)
            p += 12


def parse_fnt(d, base):
    """Extract the descriptive header fields of an FNT resource at `base`."""
    ver = u16(d, base + 0)
    face_off = u32(d, base + 105)
    face = ''
    if face_off and base + face_off < len(d):
        e = d.index(b'\0', base + face_off)
        face = d[base + face_off:e].decode('latin1')
    return {
        'ver': ver,
        'size': u32(d, base + 2),
        'points': u16(d, base + 68),
        'vres': u16(d, base + 70),
        'hres': u16(d, base + 72),
        'ascent': u16(d, base + 74),
        'charset': u8(d, base + 85),
        'w': u16(d, base + 86),
        'h': u16(d, base + 88),
        'avgw': u16(d, base + 91),
        'maxw': u16(d, base + 93),
        'first': u8(d, base + 95),
        'last': u8(d, base + 96),
        'widthbytes': u16(d, base + 99),
        'bitsoff': u32(d, base + 113),
        'face': face,
        'base': base,
    }


def glyph_bits(d, base, f, ch):
    """Return `h` rows of `w` booleans for character code `ch`.

    Raster FNT glyphs are stored column-major in 8-pixel-wide strips: all `h`
    bytes of the leftmost 8 columns, then the next strip, and so on.
    """
    if not (f['first'] <= ch <= f['last']):
        return None
    idx = ch - f['first']
    ver, h = f['ver'], f['h']
    if ver == 0x200:
        ent = base + 118 + idx * 4
        gw, goff = u16(d, ent), u16(d, ent + 2)
    else:
        ent = base + 148 + idx * 6
        gw, goff = u16(d, ent), u32(d, ent + 2)
    strips = (gw + 7) // 8
    rows = []
    for y in range(h):
        bits = []
        for s in range(strips):
            byte = d[base + goff + s * h + y]
            for b in range(8):
                if s * 8 + b < gw:
                    bits.append(bool(byte & (0x80 >> b)))
        rows.append(bits)
    return gw, rows


def find_face(data, size=(4, 6)):
    for off, _ in ne_font_resources(data):
        f = parse_fnt(data, off)
        if (f['w'], f['h']) == size:
            return off, f
    return None, None


def emit_atlas(fon_path, out_path):
    d = open(fon_path, 'rb').read()
    off, f = find_face(d)
    if f is None:
        raise SystemExit(f'{fon_path}: no 4x6 face found')
    out = bytearray()
    for c in range(256):
        for row in glyph_bits(d, off, f, c)[1]:
            out.append(sum(0x80 >> i for i, b in enumerate(row) if b))
    open(out_path, 'wb').write(bytes(out))
    print(f'{fon_path} -> {out_path} ({len(out)} bytes, 256 glyphs x 6 rows)')


if __name__ == '__main__':
    if sys.argv[1] == '--emit':
        emit_atlas(sys.argv[2], sys.argv[3])
        raise SystemExit

    directory = sys.argv[1]
    want = None
    if len(sys.argv) > 3:
        want = (int(sys.argv[2]), int(sys.argv[3]))
    hits = []
    for fn in sorted(os.listdir(directory)):
        if not fn.lower().endswith('.fon'):
            continue
        path = os.path.join(directory, fn)
        d = open(path, 'rb').read()
        for off, _ln in ne_font_resources(d):
            try:
                f = parse_fnt(d, off)
            except Exception as e:
                print(f'{fn}: parse error {e}')
                continue
            if want and (f['w'], f['h']) != want:
                continue
            hits.append((fn, f))
            print(f"{fn:16s} {f['w']:3d}x{f['h']:<3d} face={f['face']:<14s} "
                  f"charset={f['charset']:3d} chars={f['first']}-{f['last']} "
                  f"ver={f['ver']:#06x} avgw={f['avgw']} maxw={f['maxw']}")
    print(f'\n{len(hits)} matching font resources')
