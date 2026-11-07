#!/usr/bin/env bash
# Builds USERDATA_MIN_A03G.tar: a minimal Debian 12 (bookworm) arm64 root filesystem as a sparse ext4 userdata.img.
# Contents: systemd, openssh-server (root login, password 1234), USB network (192.168.7.2/24), first-boot filesystem
# grow. Nothing else: no users, no apps, no logs.
set -eu
W=$HOME/work; R=$W/rootfs; REPO=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$W/release" && cd "$W"

echo "=== debootstrap minbase (stage 1)"
sudo debootstrap --arch=arm64 --foreign --variant=minbase \
  --include=systemd,systemd-sysv,udev,openssh-server,iproute2,iputils-ping,procps,kmod,nano \
  bookworm "$R" http://deb.debian.org/debian
sudo cp /usr/bin/qemu-aarch64-static "$R/usr/bin/"
echo "=== debootstrap (stage 2)"
sudo chroot "$R" /debootstrap/debootstrap --second-stage
printf '#!/bin/sh\nexit 101\n' | sudo tee "$R/usr/sbin/policy-rc.d" >/dev/null; sudo chmod +x "$R/usr/sbin/policy-rc.d"
for d in proc sys dev dev/pts; do sudo mount --bind /$d "$R/$d"; done

echo "=== configuration"
echo 'root:1234' | sudo chroot "$R" chpasswd
echo a03 | sudo tee "$R/etc/hostname" >/dev/null
printf '127.0.0.1 localhost\n127.0.1.1 a03\n' | sudo tee "$R/etc/hosts" >/dev/null
printf '# the root filesystem is mounted by the initramfs\n' | sudo tee "$R/etc/fstab" >/dev/null
sudo mkdir -p "$R/etc/ssh/sshd_config.d" "$R/etc/systemd/logind.conf.d" "$R/etc/systemd/journald.conf.d" "$R/var/log/journal" "$R/var/lib" "$R/usr/local/sbin"
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' | sudo tee "$R/etc/ssh/sshd_config.d/10-a03.conf" >/dev/null
printf '[Login]\nHandlePowerKey=ignore\nHandleSuspendKey=ignore\nHandleHibernateKey=ignore\nHandleLidSwitch=ignore\n' | sudo tee "$R/etc/systemd/logind.conf.d/10-a03.conf" >/dev/null
printf '[Journal]\nStorage=persistent\nSystemMaxUse=50M\n' | sudo tee "$R/etc/systemd/journald.conf.d/10-a03.conf" >/dev/null
sudo chroot "$R" ssh-keygen -A

sudo install -m 0755 "$REPO/rootfs-overlay/usr/local/sbin/a03-usb-net" "$R/usr/local/sbin/a03-usb-net"
sudo install -m 0644 "$REPO/rootfs-overlay/etc/systemd/system/a03-usb-net.service" "$R/etc/systemd/system/a03-usb-net.service"
sudo install -m 0644 "$REPO/rootfs-overlay/etc/systemd/system/a03-resizefs.service" "$R/etc/systemd/system/a03-resizefs.service"
sudo chroot "$R" systemctl enable ssh.service a03-usb-net.service a03-resizefs.service
# relative link so the initramfs check finds it
sudo ln -sf ../lib/systemd/systemd "$R/usr/sbin/init"
ls -l "$R/usr/sbin/init" "$R/sbin/init" "$R/usr/lib/systemd/systemd"

echo "=== checks"
sudo chroot "$R" /usr/sbin/sshd -t && echo "sshd config ok"
sudo chroot "$R" dpkg --audit && echo "dpkg ok"
grep -n 'UDC' "$R/usr/local/sbin/a03-usb-net"
sudo chroot "$R" systemctl list-unit-files --state=enabled --no-pager | head -40

echo "=== cleanup"
sudo rm -f "$R/usr/sbin/policy-rc.d" "$R/usr/bin/qemu-aarch64-static"
sudo rm -rf "$R/var/cache/apt/archives/"*.deb "$R/var/lib/apt/lists/"* "$R/tmp/"*
for d in dev/pts dev sys proc; do sudo umount -l "$R/$d" 2>/dev/null || true; done
sudo du -sm "$R"

echo "=== sparse ext4 image (only features the 4.14 kernel knows)"
USED=$(sudo du -sm "$R" | cut -f1)
IMG_MB=$(( USED * 2 + 512 )); [ "$IMG_MB" -lt 1536 ] && IMG_MB=1536
echo "used ${USED} MB -> image ${IMG_MB} MB"
cat > mke2fs.conf <<'EOC'
[defaults]
	base_features = sparse_super,large_file,filetype,resize_inode,dir_index,ext_attr
	default_mntopts = acl,user_xattr
	blocksize = 4096
	inode_size = 256
	inode_ratio = 16384
[fs_types]
	ext4 = {
		features = has_journal,extent,huge_file,flex_bg,dir_nlink,extra_isize,64bit
	}
EOC
truncate -s "${IMG_MB}M" userdata.raw
sudo MKE2FS_CONFIG="$W/mke2fs.conf" mkfs.ext4 -F -t ext4 -L userdata -b 4096 -d "$R" userdata.raw
sudo rm -rf "$R"
sudo e2fsck -fn userdata.raw
img2simg userdata.raw userdata.img 4096
rm -f userdata.raw
simg2img userdata.img chk.raw
sudo e2fsck -fn chk.raw
mkdir -p chk && sudo mount -o ro,loop chk.raw chk
ls -l chk/usr/sbin/init chk/usr/lib/systemd/systemd chk/etc/systemd/system/multi-user.target.wants
[ -x chk/usr/sbin/init ] && echo "usr/sbin/init resolves from outside (ok for the initramfs)"
sudo umount chk; rm -f chk.raw

mkdir -p ap && cp userdata.img ap/
( cd ap && tar --format=ustar --owner=0 --group=0 --numeric-owner -cf "$W/release/USERDATA_MIN_A03G.tar" userdata.img )
tar -tvf "$W/release/USERDATA_MIN_A03G.tar"
