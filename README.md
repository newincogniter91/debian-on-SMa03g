# debian-on-SMa03g

**Debian 12 (bookworm, arm64) as a headless server on a Samsung Galaxy A03 (SM-A035G).**

Give a phone with a dead screen a second life as a tiny always-on Linux box reachable over ssh.
Everything here was developed and tested on a unit whose display was completely destroyed, so the whole
flow is done without ever looking at the screen: flash with Odin, talk to the phone over a USB network
link, log in with ssh.

> **Use at your own risk.** Flashing can brick the phone. You need an **unlocked bootloader** (this wipes the
> phone and trips Knox). Not affiliated with Samsung. See [Legal](#legal).

- [What is in the release](#what-is-in-the-release)
- [Flashing step by step](#flashing-step-by-step)
- [First boot](#first-boot)
- [Wi-Fi (optional)](#wi-fi-optional)
- [Problems we hit and how to fix them](#problems-we-hit-and-how-to-fix-them)
- [Screen and remote desktop](#screen-and-remote-desktop)
- [Building everything yourself](#building-everything-yourself)
- [Legal](#legal)

Italian version: [README.it.md](README.it.md). If you want an AI agent to work on this repo, point it at
[CLAUDE.md](CLAUDE.md).

## What is in the release

Everything is built from scratch by the GitHub Actions workflows in this repo (no hand-made binaries).

| File | What it is | How it is installed |
|---|---|---|
| `AP_REC_KSTOCK_VBSTOCK_A03G.tar` | **Rescue recovery.** Samsung's stock recovery kernel + our rescue ramdisk + the stock `vbmeta`. It brings up a USB network (phone `192.168.7.2`), a root shell on TCP **2323** and an image flasher on TCP **1234**. | Odin, AP slot |
| `USERDATA_MIN_A03G.tar` | **The Debian root filesystem** (`userdata.img`, sparse ext4): systemd, openssh-server, `root` / password `1234`, USB network `192.168.7.2/24`. Nothing else: no extra users, no apps. It grows to fill the whole partition on first boot. | Odin, AP slot (rescue flasher as a fallback, see [problems](#odin-fails-on-userdataimg)) |
| `AP_BOOT_WDT_A03G.tar` | **`boot.img`**: Linux 4.14.199 built from Samsung's open source release with the options Debian/systemd needs and the PMIC watchdog disabled, plus an initramfs that mounts Debian from `userdata` (and drops to the rescue shell if that fails). | Odin, AP slot |
| `a03-wifi.tar.gz` | *Optional.* Unisoc Wi-Fi driver package (stock modules, WCN files, firmware, `install.sh`) to extract on the running Debian. | `scp` + `./install.sh` |
| `Image`, `kernel.config`, `Module.symvers`, `modules.tar.gz`, `crc-report.txt` | Kernel build outputs (the modules and CRC report are needed by the Wi-Fi package). | - |
| `SM-A035F_13_Opensource*.zip` | Samsung's kernel source (GPL). Samsung only publishes the **A035F** variant; it is the closest one. | build input |
| `stock-extract.tar.gz` | The few pieces of the stock firmware the builds need (stock `boot.img`, `recovery.img`, `vbmeta.img`, Wi-Fi/BT modules, WCN files and firmware). | build input |
| `*.sha256` | Checksums. | - |

## Flashing step by step

You need: a Windows PC with **Odin 3.14** and the Samsung USB driver, an `ncat` (it comes with Nmap) and an ssh
client. The phone must have an unlocked bootloader. **Flash the three files in this order and reboot the phone after
each flash.**

### 0. Download mode

Power the phone off, then (on the A03 this is normally) hold **Volume Up + Volume Down** while plugging in the USB cable. Confirm the warning
screen (blind, if the display is dead). Odin reports the device as added when it is in download mode.

In Odin load each `.tar` in the **AP** slot only, leave the other slots empty and flash.

### 1. Rescue recovery: `AP_REC_KSTOCK_VBSTOCK_A03G.tar`

Flash it with Odin (AP slot), wait for `PASS`, reboot the phone.

*Optional, whenever you need a shell on the phone without Debian:* reboot into recovery (phone off, USB cable
connected, hold **Volume Up + Power**). A new **RNDIS network adapter** appears on the PC; give it a static IPv4
address, no gateway: `192.168.7.1`, mask `255.255.255.0`. Then `ping 192.168.7.2` and `ncat 192.168.7.2 2323` for the
root shell.

### 2. Debian root filesystem: `USERDATA_MIN_A03G.tar`

Back to download mode, flash it with Odin in the **AP** slot like the others and reboot the phone. It is a big
sparse image, so Odin takes a while to write it.

*Fallback if Odin fails on it* (see [problems](#odin-fails-on-userdataimg)): boot the rescue recovery from step 1 and,
from a Windows `cmd.exe` in the folder holding the file, run `ncat 192.168.7.2 1234 < USERDATA_MIN_A03G.tar`. The
flasher ends with `DONE: ... no errors`; then run `reboot -f` in the shell (`ncat 192.168.7.2 2323`). For very big
files you can also run `xfer-start` in the shell, copy the `.tar` onto the 4 GiB `A03XFER` USB disk that appears on
the PC, eject it and run `xfer-flash` (this scribbles over a 4 GiB area near the end of `userdata`; the filesystem
grows over it on first boot).

### 3. Boot image: `AP_BOOT_WDT_A03G.tar`

Back to download mode, flash it with Odin (AP slot), let the phone reboot. After a minute or two:

```
ssh root@192.168.7.2          # password: 1234
```

(Keep the PC's RNDIS adapter at `192.168.7.1/24`.)

> Do **not** flash Samsung's stock AP afterwards unless you want Android back: it overwrites boot and userdata.

## First boot

- The filesystem expands to the full partition by itself (`df -h /` should show ~50 GB).
- **Change the password** (`passwd`). `1234` is only there so you can get in.
- The only network is the USB link. To let the phone reach the internet, share the PC's connection over it:
  - Linux PC: `sudo sysctl -w net.ipv4.ip_forward=1 && sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 -j MASQUERADE`,
    then on the phone `ip route add default via 192.168.7.1 && echo 'nameserver 1.1.1.1' > /etc/resolv.conf`.
  - Windows (Internet Connection Sharing): ICS re-addresses the adapter to `192.168.137.1`. On the phone use
    `ip addr add 192.168.137.2/24 dev usb0 && ip route add default via 192.168.137.1` plus the `resolv.conf` line above.
- The phone has no screen handling (see [below](#screen-and-remote-desktop)) and nothing but ssh runs on it.

## Wi-Fi (optional)

The Wi-Fi chip needs Samsung's stock Unisoc modules and firmware, so it ships as a separate package.
The phone needs internet once (see above) so `install.sh` can `apt install network-manager wpasupplicant iw`.

```
scp a03-wifi.tar.gz root@192.168.7.2:
ssh root@192.168.7.2
tar xzf a03-wifi.tar.gz && cd a03-wifi && ./install.sh
nmcli device wifi list
nmcli device wifi connect "NETWORK_NAME" password "PASSWORD"
```

Log: `/var/log/a03-wifi.log`. The package only works with the kernel from the same release (the modules are
binary blobs checked by exact symbol CRCs). `./install.sh --no-boot` does not load Wi-Fi at boot.

## Problems we hit and how to fix them

### "No space left" although the phone is empty

`df -h` shows `/` as ~1.5 GB while the partition is ~50 GB:

```
/dev/mmcblk0p55  1.5G  1.2G  291M  81% /
```

**Cause:** the root filesystem image is built small (1.5 GB) and flashed into a much bigger partition; ext4 keeps its
original size. **Fix:** grow it online, no unmounting needed:

```
resize2fs "$(findmnt -no SOURCE /)"
```

The 1.0 image does this by itself on first boot (`a03-resizefs.service`); the manual command is for older images.
(On our unit the partition was `/dev/mmcblk0p55`; do not assume yours is the same.)

### Debian boots but there is no USB network / no ssh

**Cause (older images):** `a03-usb-net` decided the USB gadget was already attached with `[ -s "$G/UDC" ]`, which is
*always true* on configfs (the file reports its size as non-empty), so the gadget never attached to the USB controller
and `usb0` never appeared. **Fixed** in this release (the check is now `[ -z "$(cat "$G/UDC")" ]`).

To repair an older image from the rescue shell (`ncat 192.168.7.2 2323`):

```
P=$(for u in /sys/class/block/*/uevent; do grep -qx PARTNAME=userdata $u && { d=${u%/uevent}; echo /dev/${d##*/}; }; done)
mkdir -p /newroot; mount -t ext4 $P /newroot
sed -i 's|^.*-s "\$G/UDC".*$|[ -z "$(cat "$G/UDC" 2>/dev/null)" ] \&\& echo "$UDC" > "$G/UDC"|' /newroot/usr/local/sbin/a03-usb-net
grep -n UDC /newroot/usr/local/sbin/a03-usb-net
sync; umount /newroot; echo done
```

### Odin fails on userdata.img

If Odin stops with `Complete(Write) operation failed` while writing the sparse `userdata.img`, use the rescue flasher
(`a03d`, port 1234, see step 2): it understands sparse images and writes the "don't care" chunks as zeros so ext4 never
sees leftovers.

### Bootloop, or the phone looks dead

What happened to us: a bad boot/vbmeta combination made Android's first-stage init die (`avb_slot_verify failed`, then
`Attempted to kill the init task!` and a reboot, forever). Later the phone showed **no sign of life at all**: no download
mode, no recovery, no charging, nothing on the PC.

1. Try download mode again (Volume Up + Volume Down while plugging USB) and flash **Samsung's complete stock firmware**
   (BL, AP, CP, CSC) with Odin. That restores Android and the original partitions; then start over from step 1.
2. If the phone is completely dead: this is advanced and at your own risk. We opened the phone, reconnected the battery
   and touched the **test point (PWR/GND pads)** while connecting USB. It restarted in a bootloop and then entered
   download mode, from where the stock firmware could be flashed.
3. To see why it rebooted, boot the rescue recovery and read the kernel's pstore:
   `mount -t pstore pstore /sys/fs/pstore && ls /sys/fs/pstore` (`console-ramoops-0`, `dmesg-ramoops-0`).
   Flashing the stock AP wipes the Debian logs on `userdata`, so read them first.

### The phone reset itself every 5-7 minutes

With the first kernels Debian ran for roughly 5 to 7 minutes and then the device reset without any panic. The kernel in
this release disables the PMIC watchdog (patch in `.github/workflows/kernel.yml`) to address that. If you build your own
kernel, keep that patch.

### Wi-Fi: no `wlan0`

Read `/var/log/a03-wifi.log` and `dmesg | tail -n 80`. The usual cause is a kernel whose release string differs from
the package's. Do not enable the `sysv` option group in `kernel.yml`: it changes symbol CRCs and the stock Wi-Fi modules
no longer load (the workflow refuses to publish such a kernel).

## Flashlight (experimental, pre-release only)

The kernel built with the `torch` option group has `CONFIG_LEDS_GPIO`, and the boot image adds two `gpio-leds` nodes to
the stock dtb: `/sys/class/leds/white:torch-chip-en` (ap_gpio 138) and `/sys/class/leds/white:torch` (ap_gpio 32).
The GPIO numbers come from the Unisoc UMS9230 reference overlays (OCP8137 flash IC), **not** from a Samsung SM-A035G
source: they are untested on the phone, and the LED may stay dark if the IC also needs an I2C setup. Try it with
`echo 1 > .../white:torch-chip-en/brightness; echo 1 > .../white:torch/brightness` (0 to turn it off).

## USB drives and filesystems

Since `v2.0` the kernel answers to `mount -t exfat` (driver `arter97/exfat-linux`, built in; Samsung's `sdfat` is also
there but only under the type name `sdfat`). Already supported before: `vfat`/`msdos`, `ntfs`, `ext2`/`ext3`/`ext4`,
`hfs`/`hfsplus`, `udf`, `iso9660`, `xfs`, `btrfs`, `f2fs`, `jfs`, `nilfs2`, `squashfs`, `cramfs`, `minix`, FUSE. With the
`fs` option group the kernel also has hpfs, reiserfs, ufs, sysv, qnx4/6, bfs, efs, romfs, omfs, affs, adfs, befs and
freevxfs (read-only where the driver makes writing risky). All of this is built into the kernel: no modules to install.
It is **untested on the phone**. The minimal Debian image has no filesystem tools, so on the phone run
`apt install exfatprogs ntfs-3g dosfstools` (and `e2fsprogs`, `xfsprogs`, `btrfs-progs`, `f2fs-tools` if you need to
format or repair those). There is no automounting: `mount /dev/sda1 /mnt`.

## Screen and remote desktop

We did **not** think about the screen: the test unit's display was destroyed, so nothing can be seen and the panel is
not managed in any way (it does not switch off and there is no display handling or desktop). If you want a graphical
session, you can install a desktop and use **xrdp** (RDP) over the USB or Wi-Fi link. This is untested here. One caveat we
did hit: xrdp's default Xorg backend needs SysV IPC, which this kernel does not have (enabling it breaks the stock Wi-Fi
modules, see above), so use xrdp with an **Xvnc** session instead.

## Building everything yourself

All builds run on GitHub Actions (nothing is built by hand). The inputs (Samsung kernel sources and the small stock
firmware extract) live in the release itself, so a fork only needs to point `INPUTS_REPO` in the workflows at its own
copy of the release.

1. Run **kernel** (`workflow_dispatch`). It builds the kernel, uploads `Image`, modules and the CRC report, and then
   starts **boot-wdt** (`AP_BOOT_WDT_A03G.tar`) and **wifi** (`a03-wifi.tar.gz`) by itself.
2. Run **recovery** (`AP_REC_KSTOCK_VBSTOCK_A03G.tar`).
3. Run **userdata** (`USERDATA_MIN_A03G.tar`).

Layout: `.github/workflows/` (the five workflows), `scripts/` (build scripts), `initramfs/` (rescue daemon `a03d.c`,
`init.sh`, USB transfer helpers), `rootfs-overlay/` (files placed in the Debian image), `wifi/` (Wi-Fi package files).

## Legal

Scripts and workflows: MIT (see `LICENSE`). The kernel is built from Samsung's GPL-2.0 open source release. The
images also contain Samsung's stock recovery kernel, stock `vbmeta`, device tree and the Wi-Fi/BT firmware and modules,
which stay under Samsung's own terms. This project is unofficial and comes with no warranty.
