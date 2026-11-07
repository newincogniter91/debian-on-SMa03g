#!/usr/bin/env python3
"""Adds the torch LEDs (gpio-leds) to the stock Unisoc dtb container used in boot.img.

usage: add-torch-dtb.py stock.dtb out.dtb

The stock dtb has the Unisoc table header (magic d7b7ab1e, one entry) followed by a single flattened tree and no
board overlay, so it has no flash node at all. GPIO numbers are the ones of the OCP8137 flash IC in the Unisoc
UMS9230 1H10/3H10/4H10 reference overlays (torch-en 32, chip-en 138 on the ap_gpio controller). They are NOT confirmed
on the Samsung SM-A035G: that is what the pre-release is for.
"""
import struct, subprocess, sys, tempfile, os

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()
magic, total = struct.unpack_from(">II", d, 0)
assert magic == 0xD7B7AB1E, "not a Unisoc dtb container"
hdr_size, ent_size, ent_count, ent_off = struct.unpack_from(">IIII", d, 8)
assert ent_count == 1, "expected exactly one dtb in the container"
dtb_size, dtb_off = struct.unpack_from(">II", d, ent_off)
head, tree = d[:dtb_off], d[dtb_off:dtb_off + dtb_size]
assert tree[:4] == b"\xd0\x0d\xfe\xed"

with tempfile.TemporaryDirectory() as t:
    p = os.path.join(t, "t.dtb")
    open(p, "wb").write(tree)
    ph = subprocess.run(["fdtget", p, "/soc/aon/gpio@641b0000", "phandle"], check=True, capture_output=True, text=True).stdout.split()[0]
    ph = int(ph)
    def put(*a):
        subprocess.run(["fdtput", *a], check=True)
    put("-c", p, "/torch-leds")
    put("-t", "s", p, "/torch-leds", "compatible", "gpio-leds")
    for name, gpio in (("torch-chip-en", 138), ("torch", 32)):
        n = "/torch-leds/" + name
        put("-c", p, n)
        put("-t", "s", p, n, "label", "white:" + name)
        put("-t", "u", p, n, "gpios", str(ph), str(gpio), "0")
        put("-t", "s", p, n, "default-state", "off")
    tree = open(p, "rb").read()

new_total = len(head) + len(tree)
head = bytearray(head)
struct.pack_into(">I", head, 4, new_total)
struct.pack_into(">I", head, ent_off, len(tree))
open(dst, "wb").write(bytes(head) + tree)
print("torch dtb: %d -> %d bytes, ap_gpio phandle %d" % (dtb_size, len(tree), ph))
