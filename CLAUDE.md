# CLAUDE.md: briefing for AI agents working on this repo

You are working on **debian-on-SMa03g**: Debian 12 (bookworm, arm64) running headless on a **Samsung Galaxy A03,
model SM-A035G** (Unisoc SoC, `qogirl6` family, eMMC, Android 13 firmware `A035GXXS8CYG1`, Linux **4.14.199**).
The goal is an always-on ssh server on a phone whose screen is destroyed. Read this whole file before touching anything.
Human-facing docs are in `README.md` (English) and `README.it.md` (Italian); keep them in sync with what you change.

## Ground rules

1. **Everything is built on GitHub Actions**, never by hand and never in a chat sandbox. A change is "done" when the
   workflow that builds it has run and uploaded its asset to the release. Prefer starting a run and moving on over
   waiting for it; the maintainer says when it finished.
2. **Make only the changes that were asked for.** Prefer small targeted edits over rewriting files.
3. **No secrets, personal data or personal accounts in the repo, the images or the logs.** The only credential in the
   product is the documented default `root` / `1234`, and the docs tell people to change it.
4. **Do not invent hardware facts.** If you did not see it in a log or a source, say it is untested.
5. Flashing is risky for real people's phones: when you change anything that touches boot, vbmeta, the initramfs or
   partition writing, say so explicitly in the change description.

## The three artifacts (flash order) and how each is built

| Artifact | Workflow | Script | What is inside |
|---|---|---|---|
| `AP_REC_KSTOCK_VBSTOCK_A03G.tar` | `recovery.yml` | `scripts/build-initramfs.sh recovery` | `recovery.img` (stock recovery header + stock kernel, our ramdisk) + stock `vbmeta.img` |
| `USERDATA_MIN_A03G.tar` | `userdata.yml` | `scripts/build-userdata.sh` | `userdata.img`: sparse ext4 with a minimal Debian 12 |
| `AP_BOOT_WDT_A03G.tar` | `boot-wdt.yml` | `scripts/build-initramfs.sh boot` | `boot.img` only: our kernel `Image` + our ramdisk + stock dtb |
| `a03-wifi.tar.gz` (optional) | `wifi.yml` | `scripts/build-wifi.sh` | stock Unisoc Wi-Fi modules + firmware + `wifi/install.sh` |

`kernel.yml` builds the kernel and uploads `Image`, `kernel.config`, `Module.symvers`, `crc-report.txt`,
`modules.tar.gz`, then dispatches `boot-wdt.yml` and `wifi.yml`. Inputs (Samsung kernel sources
`SM-A035F_13_Opensource*.zip` and `stock-extract.tar.gz` holding the stock `boot.img`, `recovery.img`, `vbmeta.img`,
`out/socko/*.ko` and `out/vendor-modules-firmware.tar.gz`) and all outputs live in **one GitHub release** (`v1.0`,
selectable with the `tag` input). Workflows read inputs with `gh release download --repo $INPUTS_REPO`.

## Repository map

- `initramfs/a03d.c`: rescue daemon. Port **2323** = unauthenticated root shell, port **1234** = receives an Odin-style
  `ustar` tar and writes `boot`, `userdata`, `vbmeta`, `dtbo`, `recovery` partitions (looked up by `PARTNAME=`;
  anything else is refused; sparse images are expanded with DONT_CARE written as zeros). `a03d --flash < file.tar` does
  the same from stdin.
- `initramfs/init.sh`: PID 1 of the ramdisk. `/mode` = `boot` tries to mount the `userdata` partition (waits up to 90 s,
  ext4, `noatime`), checks for `/sbin/init` or systemd, copies its log to `/var/log/a03-initramfs.log` on the root fs
  and `switch_root`s. On any failure, or in mode `recovery`, it starts the USB RNDIS gadget (phone `192.168.7.2/24`),
  `a03d`, and sleeps.
- `initramfs/xfer-start`, `xfer-flash`: expose a 4 GiB FAT32 USB disk (loop device at offset 40 GiB of `userdata`) so
  a PC can copy a big tar quickly, then flash it with `a03d`.
- `rootfs-overlay/`: `a03-usb-net` (configfs RNDIS gadget + static IP) and systemd units, installed by
  `build-userdata.sh`. `a03-resizefs.service` grows ext4 to the whole partition on first boot.
- `wifi/`: `install.sh` (run on the phone), `a03-wifi-up` (creates `/dev/block/by-name`, `/data/vendor/*`, loads
  `sprdwl_ng`), `a03-wifi.service`.
- `scripts/crc-check.py`: compares the `__versions` CRCs of the stock `.ko` modules with our `Module.symvers`.

## Hard constraints (each one cost us days: do not break them)

- **Stock Wi-Fi/BT modules are closed binaries.** They load only if (a) the kernel release string equals the stock
  vermagic (`kernel.yml` derives `LOCALVERSION` from `sprdwl_ng.ko` so `uname -r` becomes
  `4.14.199-27193134-abA035GXXS8CYG1`) and (b) every exported symbol CRC matches. `crc-check.py` enforces (b) and the
  workflow refuses to publish a kernel that fails. The option group `sysv` (SYSVIPC) changes CRCs and breaks Wi-Fi;
  that is why the kernel has no SysV IPC and xrdp's Xorg backend crashes (use an Xvnc session).
- **PMIC watchdog.** Debian used to run ~5-7 minutes and then the device reset with no panic. The kernel build patches
  `drivers/watchdog/sprd_pmic_wdt.c` to switch it off. Keep the patch.
- **Boot image format.** Header v2, page size 2048, base `0x0`, kernel offset `0x8000`, ramdisk offset `0x1000000`,
  dtb offset `0x1f00000`, stock dtb, board `SRPUI23C008`, cmdline `console=ttyS1,115200n8`. Must stay < 64 MiB.
  The recovery image reuses the stock recovery header arguments (taken with `unpack_bootimg --format=mkbootimg`) with
  only the ramdisk replaced.
- **AVB.** The bootloader is unlocked but `vbmeta` still matters: a wrong boot/vbmeta pair makes Android's first-stage
  init die (`avb_slot_verify failed`) and the phone bootloops. The recovery artifact ships the *stock* `vbmeta`; the
  boot artifact deliberately ships only `boot.img`.
- **Odin tars** are plain `ustar` (no `.md5`), AP slot only, and all three artifacts are flashed that way, userdata
  included. If Odin ever fails on the big sparse `userdata.img` (`Complete(Write) operation failed`, seen on one unit),
  `a03d` on port 1234 is the documented fallback.
- **ext4 features.** The 4.14 kernel does not know newer mke2fs defaults; `build-userdata.sh` uses an explicit
  `mke2fs.conf`. Keep it.
- **configfs gotcha.** `[ -s "$G/UDC" ]` is always true on configfs, which silently prevented the USB gadget from
  attaching. Test emptiness with `[ -z "$(cat "$G/UDC")" ]`.
- **Partition numbers differ between units.** Never hardcode `mmcblk0p55`; find partitions by `PARTNAME=` in
  `/sys/class/block/*/uevent`.
- The Wi-Fi stack expects Android-isms (`/dev/block/by-name`, `/data/vendor/wifi`, some uptime before probing);
  `a03-wifi-up` provides them.

## How to debug a device that will not boot

1. Rescue recovery: phone off, cable in, Volume Up + Power. PC adapter `192.168.7.1/24`, `ncat 192.168.7.2 2323`.
2. `mount -t pstore pstore /sys/fs/pstore` and read `console-ramoops-0` / `dmesg-ramoops-0` for the last boot.
3. Mount the `userdata` partition and read `/var/log/a03-initramfs.log` and the persistent journal.
4. Flashing Samsung's stock AP restores Android **and erases those logs**: read them first.
5. A phone with no sign of life may need the hardware test-point procedure described in the README. Treat it as a
   last resort and warn the user.

## Extending it

- *Add a package or a file to the Debian image:* edit `scripts/build-userdata.sh` (`--include=` list or the
  configuration section) or `rootfs-overlay/`, then run `userdata.yml`. Keep the image minimal; never add user
  accounts, credentials or personal data.
- *Add kernel options:* add a named group to the `case` in `kernel.yml`, build with `groups=<name>`, and check
  `crc-report.txt` still says `TOTAL problems: 0` before using it with the stock Wi-Fi modules.
- *Change the flasher protocol or partition allow-list:* `initramfs/a03d.c` (`allowed()`), then rebuild **both**
  boot and recovery ramdisks.
- Order of rebuilds after a kernel change: `kernel` (it dispatches `boot-wdt` and `wifi`). The recovery and userdata
  artifacts do not depend on the kernel.

## Known gaps

No display or desktop support (the test unit's screen was destroyed; the panel is not managed and never switches off);
xrdp is untested here; no battery charge limit, zram/swap tuning, Bluetooth, USB OTG automounting or samba in the
minimal image; the rescue shell on port 2323 has no authentication (it exists only on the USB link in recovery mode);
the default `root` / `1234` login is meant to be changed.
