import zlib, struct, sys

def load_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos = 8
    idat = b''
    w = h = bit = ctype = None
    plte = None
    trns = None
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos+4])[0]
        typ = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+ln]
        pos += 12 + ln
        if typ == b'IHDR':
            w, h, bit, ctype, comp, filt, inter = struct.unpack('>IIBBBBB', chunk)
        elif typ == b'IDAT':
            idat += chunk
        elif typ == b'PLTE':
            plte = chunk
        elif typ == b'tRNS':
            trns = chunk
        elif typ == b'IEND':
            break
    raw = zlib.decompress(idat)
    nch = {0:1, 2:3, 3:1, 4:2, 6:4}[ctype]
    bpp = max(1, nch * bit // 8)
    stride = (w * nch * bit + 7) // 8
    out = bytearray(h * stride)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i-bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i-bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i-bpp] if i >= bpp else 0
                pa, pb, pc = abs(b-c), abs(a-c), abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, bit, ctype, bytes(out), plte, trns

def gray_of(path):
    w, h, bit, ctype, raw, plte, trns = load_png(path)
    assert bit == 8
    if ctype == 0:
        g = list(raw)
    elif ctype == 4:
        g = [raw[i*2] for i in range(w*h)]
    elif ctype == 3:
        g = [plte[raw[i]*3] for i in range(w*h)]
    elif ctype == 2:
        g = [raw[i*3] for i in range(w*h)]
    else:
        g = [raw[i*4] for i in range(w*h)]
    return w, h, g

if __name__ == '__main__':
    for p in sys.argv[1:]:
        w, h, g = gray_of(p)
        ink = [(i % w, i // w) for i, v in enumerate(g) if v < 128]
        if ink:
            xs = [a for a, b in ink]; ys = [b for a, b in ink]
            print(f"{p}: {w}x{h} ink={len(ink)} bbox=({min(xs)},{min(ys)})-({max(xs)},{max(ys)})")
        else:
            print(f"{p}: {w}x{h} ink=0 空白图！")
