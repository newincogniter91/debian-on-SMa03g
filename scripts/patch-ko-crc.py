#!/usr/bin/env python3
# rewrites the symbol CRCs in the __versions section of a stock .ko so they match our kernel's Module.symvers
# usage: patch-ko-crc.py Module.symvers module.ko [more.ko ...]
# Only meant for the case where the struct layouts the module really uses did not change (crc_patch in kernel.yml);
# refuses to touch a module that imports a symbol our kernel does not export.
import sys, struct

def section(d, want):
    shoff = struct.unpack_from("<Q", d, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
    secs = [struct.unpack_from("<IIQQQQ", d, shoff + i * shentsize) for i in range(shnum)]
    stro = secs[shstrndx][4]
    for name, typ, flags, addr, off, size in secs:
        n = d[stro + name:d.index(b"\0", stro + name)].decode()
        if n == want: return off, size
    return None

symvers = {}
for l in open(sys.argv[1]):
    p = l.split()
    if len(p) >= 2: symvers[p[1]] = int(p[0], 16)

for ko in sys.argv[2:]:
    d = bytearray(open(ko, "rb").read())
    assert d[:4] == b"\x7fELF" and d[4] == 2, "%s: not an ELF64 file" % ko
    s = section(d, "__versions")
    assert s, "%s: no __versions section (module built without modversions?)" % ko
    off, size = s
    n = changed = 0
    for i in range(off, off + size - 63, 64):
        name = bytes(d[i+8:i+64]).split(b"\0")[0].decode()
        if not name: continue
        n += 1
        if name not in symvers:
            sys.exit("ERROR: %s imports %s, which our kernel does not export" % (ko, name))
        old = struct.unpack_from("<Q", d, i)[0]
        if (old & 0xffffffff) != symvers[name]:
            struct.pack_into("<Q", d, i, (old & ~0xffffffff) | symvers[name])
            changed += 1
    open(ko, "wb").write(d)
    print("%s: %d symbols, %d CRCs rewritten" % (ko, n, changed))
