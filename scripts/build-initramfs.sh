#!/usr/bin/env bash
# Builds the A03 initramfs used by both images:
#   mode "boot"     -> boot.img: tries to boot Debian from userdata, falls back to rescue
#   mode "recovery" -> recovery.img: goes straight to rescue (USB network, shell on :2323, flasher on :1234)
# usage: build-initramfs.sh <boot|recovery> <output.cpio.gz>
set -eu
MODE=$1; OUT=$(realpath -m "$2")
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); cd "$T"

echo "=== a03d (rescue shell + AP tar flasher), static arm64"
aarch64-linux-gnu-gcc -static -Os -Wall -o a03d "$REPO/initramfs/a03d.c"
aarch64-linux-gnu-strip a03d
file a03d

echo "=== busybox-static arm64 from Debian bookworm"
python3 - > bb-filename.txt <<'PY'
import lzma, urllib.request
d = lzma.decompress(urllib.request.urlopen('https://deb.debian.org/debian/dists/bookworm/main/binary-arm64/Packages.xz').read()).decode()
for blk in d.split('\n\n'):
    if blk.startswith('Package: busybox-static\n'):
        for l in blk.split('\n'):
            if l.startswith('Filename:'): print(l.split()[1])
PY
cat bb-filename.txt
curl -fsSL -o bb.deb "https://deb.debian.org/debian/$(cat bb-filename.txt)"
dpkg-deb -x bb.deb bb
file bb/bin/busybox

echo "=== FAT32 head (4 GiB disk, 4 KiB clusters) for the USB transfer disk"
truncate -s 4096M fat.img
mkfs.vfat -F 32 -s 8 -n A03XFER fat.img
head -c 16777216 fat.img | gzip -9 > fat32-head.gz
rm -f fat.img

echo "=== ramdisk (mode: $MODE)"
mkdir -p ramroot/bin ramroot/dev ramroot/proc ramroot/sys ramroot/newroot ramroot/run
cp bb/bin/busybox ramroot/bin/busybox
cp a03d ramroot/bin/a03d
cp "$REPO/initramfs/init.sh" ramroot/init
echo "$MODE" > ramroot/mode
cp "$REPO/initramfs/xfer-start" "$REPO/initramfs/xfer-flash" ramroot/bin/
cp fat32-head.gz ramroot/fat32-head.gz
chmod 755 ramroot/init ramroot/bin/busybox ramroot/bin/a03d ramroot/bin/xfer-start ramroot/bin/xfer-flash
( cd ramroot && find . | cpio -o -H newc --owner=0:0 2>/dev/null ) | gzip -9 > "$OUT"
ls -la "$OUT"
zcat "$OUT" | cpio -t 2>/dev/null
