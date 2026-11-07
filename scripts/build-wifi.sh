#!/usr/bin/env bash
# Wi-Fi package for the Debian already installed on the Galaxy A03G: a03-wifi.tar.gz
# = stock Unisoc modules (sprdwl_ng) + kernel modules + WCN files + Android firmware + service + install.sh
# Extract it on the phone and run ./install.sh as root; no reflash needed.
set -eu
W=$HOME/work; REPO=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$W/release" && cd "$W"

echo "=== inputs: kernel modules and stock driver/firmware extract"
gh release download "$INPUTS_TAG" --repo "$GITHUB_REPOSITORY" --pattern 'modules.tar.gz' --pattern 'crc-report.txt' --clobber
gh release download "$INPUTS_TAG" --repo "$INPUTS_REPO" --pattern 'stock-extract.tar.gz' --clobber
cat crc-report.txt
grep -q 'TOTAL problems: 0' crc-report.txt || { echo "ERROR: the stock modules are not compatible with this kernel"; exit 1; }
tar -xzf stock-extract.tar.gz out/socko out/vendor-modules-firmware.tar.gz
ls -la out/socko

P=$W/a03-wifi; R=$P/rootfs
rm -rf "$P"; mkdir -p "$R"
echo "=== kernel modules"
tar -xzf modules.tar.gz -C "$R"
KREL=$(ls "$R/lib/modules" | head -1)
echo "kernel release: $KREL"
echo "$KREL" > "$P/KREL"
echo "=== stock Android modules (extra)"
mkdir -p "$R/lib/modules/$KREL/extra"
cp out/socko/*.ko "$R/lib/modules/$KREL/extra/"
test -f "$R/lib/modules/$KREL/extra/sprdwl_ng.ko" || { echo "ERROR: sprdwl_ng.ko missing"; exit 1; }
echo "=== WCN files and firmware from the vendor partition"
mkdir -p vend && tar -xzf out/vendor-modules-firmware.tar.gz -C vend
mkdir -p "$R/vendor/etc" "$R/lib/firmware"
[ -d vend/etc/wcn ] || { echo "ERROR: etc/wcn missing from the vendor extract"; exit 1; }
cp -a vend/etc/wcn "$R/vendor/etc/"
for f in wifi_board_config.ini connectivity_configure.ini connectivity_calibration.ini; do
  [ -e "$R/vendor/etc/wcn/$f" ] && ln -sf "wcn/$f" "$R/vendor/etc/$f" || echo "WARNING: $f not found"
done
if [ -d vend/firmware ]; then cp -a vend/firmware/. "$R/lib/firmware/"; else echo "WARNING: vend/firmware missing"; fi
echo "--- vendor/etc/wcn"; ls -la "$R/vendor/etc/wcn"
echo "--- firmware: $(find "$R/lib/firmware" -type f | wc -l) files, $(du -sm "$R/lib/firmware" | cut -f1) MB"
find "$R/lib/firmware" -maxdepth 1 | head -40

echo "=== scripts, service and install.sh"
cp "$REPO/wifi/install.sh" "$REPO/wifi/a03-wifi-up" "$REPO/wifi/a03-wifi.service" "$P/"
chmod +x "$P/install.sh" "$P/a03-wifi-up"
cat > "$P/README.txt" <<EOF
Wi-Fi for Debian on the Galaxy A03G (kernel $KREL)

On the phone (over ssh):
  tar xzf a03-wifi.tar.gz
  cd a03-wifi
  sudo ./install.sh

Then:
  nmcli device wifi list
  nmcli device wifi connect "NETWORK_NAME" password "PASSWORD"

Load log: /var/log/a03-wifi.log
install.sh options: --no-boot (do not load Wi-Fi at boot), --force (skip the kernel release check)
EOF

echo "=== a03-wifi.tar.gz"
tar --owner=0 --group=0 --numeric-owner -czf "$W/release/a03-wifi.tar.gz" -C "$W" a03-wifi
ls -la "$W/release"
SZ=$(stat -c %s "$W/release/a03-wifi.tar.gz")
[ "$SZ" -lt 2147483648 ] || { echo "ERROR: package larger than 2 GiB"; exit 1; }
tar -tzf "$W/release/a03-wifi.tar.gz" | grep -v '/lib/firmware/' | head -60
( cd "$W/release" && sha256sum a03-wifi.tar.gz | tee a03-wifi.tar.gz.sha256 )
