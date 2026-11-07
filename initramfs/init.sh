#!/bin/busybox sh
# A03 initramfs. /mode = boot: try to boot Debian from userdata, fall back to rescue if that fails
#                /mode = recovery: go straight to rescue (USB network + shell + AP tar flasher)
/bin/busybox --install -s /bin
export PATH=/bin:/sbin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
if mount -t devtmpfs devtmpfs /dev 2>/dev/null; then
  DEVMODE=devtmpfs
else
  mount -t tmpfs tmpfs /dev
  mdev -s
  DEVMODE=mdev
fi
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /run
MODE=$(cat /mode 2>/dev/null)

log() {
  echo "a03-init: $*" > /dev/kmsg 2>/dev/null
  echo "$(date +%T) $*" >> /run/a03.log
}

# USB RNDIS gadget: phone 192.168.7.2/24, PC 192.168.7.1/24
usb_net() {
  mount -t configfs none /sys/kernel/config 2>/dev/null
  G=/sys/kernel/config/usb_gadget/g1
  [ -d $G/functions/rndis.usb0 ] && return
  mkdir -p $G && cd $G || return
  echo 0x1d6b > idVendor
  echo 0x0104 > idProduct
  mkdir -p strings/0x409
  echo Debian > strings/0x409/manufacturer
  echo a03-recovery > strings/0x409/product
  echo 0001 > strings/0x409/serialnumber
  mkdir -p configs/c.1/strings/0x409
  echo rndis > configs/c.1/strings/0x409/configuration
  mkdir -p functions/rndis.usb0
  mkdir -p functions/mass_storage.0
  echo 1 > functions/mass_storage.0/lun.0/removable
  echo 0 > functions/mass_storage.0/lun.0/ro
  echo 1 > os_desc/use
  echo 0xcd > os_desc/b_vendor_code
  echo MSFT100 > os_desc/qw_sign
  echo RNDIS > functions/rndis.usb0/os_desc/interface.rndis/compatible_id
  echo 5162001 > functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id
  ln -s $G/functions/rndis.usb0 $G/configs/c.1/
  ln -s $G/functions/mass_storage.0 $G/configs/c.1/ 2>/dev/null
  ln -s $G/configs/c.1 $G/os_desc/
  n=0
  while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
  UDC=$(ls /sys/class/udc | head -n1)
  echo "$UDC" > UDC
  cd /
  sleep 2
  ifconfig usb0 192.168.7.2 netmask 255.255.255.0 up 2>/dev/null || ifconfig rndis0 192.168.7.2 netmask 255.255.255.0 up 2>/dev/null
  log "USB gadget on '$UDC', ip 192.168.7.2"
}

find_part() {
  for u in /sys/class/block/*/uevent; do
    if grep -qx "PARTNAME=$1" "$u" 2>/dev/null; then d=${u%/uevent}; echo "/dev/${d##*/}"; return 0; fi
  done
  return 1
}

boot_debian() {
  UD=""; i=0
  while [ $i -lt 90 ]; do [ "$DEVMODE" = mdev ] && mdev -s; UD=$(find_part userdata) && break; sleep 1; i=$((i+1)); done
  [ -n "$UD" ] || { log "userdata partition not found"; return 1; }
  mount -t ext4 -o noatime "$UD" /newroot 2>/dev/null || { log "ext4 mount of $UD failed"; return 1; }
  [ -x /newroot/sbin/init ] || [ -x /newroot/usr/lib/systemd/systemd ] || { log "/sbin/init not found on $UD"; umount /newroot; return 1; }
  log "booting Debian from $UD"
  mkdir -p /newroot/var/log && cp /run/a03.log /newroot/var/log/a03-initramfs.log 2>/dev/null
  mount --move /dev /newroot/dev
  mount --move /proc /newroot/proc
  mount --move /sys /newroot/sys
  mount --move /run /newroot/run
  exec switch_root /newroot /sbin/init
  return 1
}

log "initramfs start (mode: $MODE, /dev: $DEVMODE)"
if [ "$MODE" = boot ]; then
  boot_debian
  log "Debian boot failed: switching to rescue"
fi

# rescue: shell on 192.168.7.2:2323, AP tar flasher on 192.168.7.2:1234
[ "$DEVMODE" = mdev ] && mdev -s
a03d &
usb_net &
log "rescue ready"
while true; do sleep 3600; done
