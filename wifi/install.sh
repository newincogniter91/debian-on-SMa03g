#!/bin/bash
# Unisoc Wi-Fi for Debian on the Galaxy A03G: stock modules, WCN files, firmware, service and NetworkManager.
# Usage, as root:   ./install.sh [--no-boot] [--force]
#   --no-boot  do not load Wi-Fi at boot (start it by hand with: systemctl start a03-wifi)
#   --force    install even if the running kernel differs from the one the modules were built for
set -u
NOBOOT=0; FORCE=0
for a in "$@"; do case "$a" in --no-boot) NOBOOT=1 ;; --force) FORCE=1 ;; esac; done
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo ./install.sh"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
KREL=$(cat "$D/KREL"); RUN=$(uname -r)
echo "running kernel:        $RUN"
echo "modules in the package: $KREL"
if [ "$RUN" != "$KREL" ] && [ "$FORCE" = 0 ]; then
  echo "ERROR: the stock modules only load on a kernel with the same release string. Nothing was changed."
  echo "(if you know what you are doing: ./install.sh --force)"
  exit 1
fi

echo "== 1/6 NetworkManager must not touch usb0 (it is your ssh link)"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/20-a03-unmanaged.conf <<'EOF1'
[keyfile]
unmanaged-devices=interface-name:usb0;interface-name:rndis0
EOF1
cat > /etc/NetworkManager/conf.d/10-a03.conf <<'EOF2'
[connection]
wifi.powersave=2
[device]
wifi.scan-rand-mac-address=no
EOF2

echo "== 2/6 modules, WCN files and firmware"
(cd "$D/rootfs" && tar -cf - .) | tar -xpf - -C / --keep-directory-symlink --no-overwrite-dir || { echo "ERROR while copying the files"; exit 1; }
if [ ! -e /vendor/firmware ]; then ln -sfn /lib/firmware /vendor/firmware; fi
depmod -a "$KREL"
modinfo -k "$KREL" sprdwl_ng | sed -n '1,4p'

echo "== 3/6 service and by-name rule"
install -m 0755 "$D/a03-wifi-up" /usr/local/sbin/a03-wifi-up
install -m 0644 "$D/a03-wifi.service" /etc/systemd/system/a03-wifi.service
cat > /etc/udev/rules.d/60-by-name.rules <<'EOF3'
# /dev/block/by-name/<name> like on Android
SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}=="?*", SYMLINK+="block/by-name/$env{PARTNAME}"
EOF3
udevadm control --reload 2>/dev/null
udevadm trigger --subsystem-match=block --action=change 2>/dev/null
mkdir -p /data/vendor/wifi /data/vendor/bluetooth

echo "== 4/6 NetworkManager, wpa_supplicant, iw"
cp -L /etc/resolv.conf /root/resolv.conf.bak 2>/dev/null
if apt-get update -qq; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends network-manager wpasupplicant iw rfkill wireless-regdb \
    || echo "WARNING: package installation failed (run ./install.sh again when the phone has internet)"
else
  echo "WARNING: apt cannot reach the internet, skipping packages (run ./install.sh again when it can)"
fi
systemctl disable NetworkManager-wait-online.service 2>/dev/null
# NetworkManager must not leave you without DNS
if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null && grep -q '^nameserver' /root/resolv.conf.bak 2>/dev/null; then
  rm -f /etc/resolv.conf; cp /root/resolv.conf.bak /etc/resolv.conf; echo "resolv.conf restored"
fi

echo "== 5/6 start"
systemctl daemon-reload
if [ "$NOBOOT" = 0 ]; then systemctl enable a03-wifi.service; else echo "(--no-boot: not enabled at boot)"; fi
systemctl restart a03-wifi.service
echo "== 6/6 result"
ip -br link
echo "--- modules:"; lsmod | grep -i -E 'sprd|wcn'
echo "--- iw:"; iw dev 2>&1 | head -12
echo "--- log (/var/log/a03-wifi.log):"; tail -n 40 /var/log/a03-wifi.log
echo
if ls /sys/class/net | grep -q '^wlan'; then
  echo "OK: Wi-Fi interface present. To connect:"
  echo "  nmcli device wifi list"
  echo "  nmcli device wifi connect \"NETWORK_NAME\" password \"PASSWORD\""
else
  echo "wlan0 is NOT there. Check the output above and:  dmesg | tail -n 80"
fi
