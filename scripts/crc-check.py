#!/usr/bin/env python3
# compares the symbol CRCs required by the stock modules (__versions section) with our kernel's Module.symvers
import sys, struct, os

def sections(path):
    d = open(path, "rb").read()
    assert d[:4] == b"\x7fELF" and d[4] == 2, "not an ELF64 file"
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = [struct.unpack_from("<IIQQQQ", d, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    out = {}
    for name, typ, flags, addr, off, size in secs:
        n = d[stro + name:d.index(b"\0", stro + name)].decode()
        out[n] = d[off:off + size]
    return out

symvers = {}
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) >= 2: symvers[p[1]] = int(p[0], 16)
tot = 0
for ko in sys.argv[2:]:
    v = sections(ko).get("__versions", b"")
    bad, missing, n = [], [], 0
    for i in range(0, len(v) - 63, 64):
        crc = struct.unpack_from("<Q", v, i)[0] & 0xffffffff
        name = v[i+8:i+64].split(b"\0")[0].decode()
        if not name: continue
        n += 1
        if name not in symvers: missing.append(name)
        elif symvers[name] != crc: bad.append((name, crc, symvers[name]))
    print("%s: symbols %d, different CRC %d, missing %d" % (os.path.basename(ko), n, len(bad), len(missing)))
    for b in bad[:40]: print("   DIFFERENT %s stock=%08x ours=%08x" % b)
    for m in missing[:40]: print("   MISSING", m)
    tot += len(bad) + len(missing)
print("TOTAL problems:", tot)
