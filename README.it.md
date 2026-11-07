# debian-on-SMa03g

**Debian 12 (bookworm, arm64) come server headless su un Samsung Galaxy A03 (SM-A035G).**

Dai una seconda vita a un telefono con lo schermo rotto trasformandolo in un mini server Linux sempre acceso,
raggiungibile via ssh. Tutto è stato sviluppato e provato su un esemplare con il display completamente distrutto,
quindi l'intero procedimento si fa senza mai guardare lo schermo: flash con Odin, rete USB, login ssh.

> **Usalo a tuo rischio.** Il flash può mandare in brick il telefono. Serve il **bootloader sbloccato** (cancella i
> dati e fa scattare Knox). Progetto non affiliato a Samsung. Vedi [Note legali](#note-legali).

Versione inglese: [README.md](README.md). Per far lavorare un'IA su questo repo, falle leggere [CLAUDE.md](CLAUDE.md).

## Cosa c'è nella release

Tutto è compilato da zero dai workflow GitHub Actions di questo repo (nessun binario fatto a mano).

| File | Cos'è | Come si installa |
|---|---|---|
| `AP_REC_KSTOCK_VBSTOCK_A03G.tar` | **Recovery di soccorso.** Kernel della recovery Samsung originale + il nostro ramdisk di soccorso + il `vbmeta` originale. Attiva una rete USB (telefono `192.168.7.2`), una shell root sulla porta TCP **2323** e un flasher di immagini sulla porta TCP **1234**. | Odin, slot AP |
| `USERDATA_MIN_A03G.tar` | **Il filesystem Debian** (`userdata.img`, ext4 sparse): systemd, openssh-server, `root` / password `1234`, rete USB `192.168.7.2/24`. Nient'altro: niente utenti o app extra. Al primo avvio si espande a tutta la partizione. | Odin, slot AP (flasher di soccorso come ripiego, vedi sotto) |
| `AP_BOOT_WDT_A03G.tar` | **`boot.img`**: Linux 4.14.199 compilato dai sorgenti open source Samsung con le opzioni per Debian/systemd e il watchdog PMIC disabilitato, più un initramfs che monta Debian da `userdata` (e passa alla shell di soccorso se fallisce). | Odin, slot AP |
| `a03-wifi.tar.gz` | *Opzionale.* Pacchetto driver Wi-Fi Unisoc (moduli stock, file WCN, firmware, `install.sh`) da estrarre su Debian già in funzione. | `scp` + `./install.sh` |
| `Image`, `kernel.config`, `Module.symvers`, `modules.tar.gz`, `crc-report.txt` | Risultati della compilazione del kernel. | - |
| `SM-A035F_13_Opensource*.zip` | Sorgenti del kernel Samsung (GPL). Samsung pubblica solo la variante **A035F**, la più vicina. | input di build |
| `stock-extract.tar.gz` | I pochi pezzi del firmware originale che servono alle build (`boot.img`, `recovery.img`, `vbmeta.img`, moduli Wi-Fi/BT, file WCN, firmware). | input di build |
| `*.sha256` | Checksum. | - |

## Come flashare, passo per passo

Servono: un PC Windows con **Odin 3.14** e il driver USB Samsung, `ncat` (incluso in Nmap) e un client ssh. Il
bootloader deve essere sbloccato. **Flasha i tre file in quest'ordine e riavvia il telefono dopo ogni flash.**

### 0. Download mode

A telefono spento, tieni premuti **Volume su + Volume giù** (sull'A03 di solito è così) mentre colleghi il cavo USB e
conferma l'avviso (alla cieca, se il display è rotto). Odin segnala il dispositivo come aggiunto.

In Odin carica ogni `.tar` **solo nello slot AP**, lascia vuoti gli altri e avvia il flash.

### 1. Recovery di soccorso: `AP_REC_KSTOCK_VBSTOCK_A03G.tar`

Flashala con Odin (slot AP), aspetta `PASS`, riavvia il telefono.

*Opzionale, quando ti serve una shell sul telefono senza Debian:* riavvia in recovery (telefono spento, cavo USB
collegato, **Volume su + Power**). Sul PC compare una **scheda di rete RNDIS**: dalle un IPv4 statico, senza gateway:
`192.168.7.1`, maschera `255.255.255.0`. Poi `ping 192.168.7.2` e `ncat 192.168.7.2 2323` per la shell root.

### 2. Filesystem Debian: `USERDATA_MIN_A03G.tar`

Torna in download mode, flashalo con Odin nello slot **AP** come gli altri e riavvia il telefono. È una immagine sparse
grossa, quindi Odin ci mette un po' a scriverla.

*Ripiego se Odin fallisce* (vedi [problemi](#odin-fallisce-su-userdataimg)): avvia la recovery di soccorso del passo 1 e,
da un `cmd.exe` di Windows nella cartella del file, esegui `ncat 192.168.7.2 1234 < USERDATA_MIN_A03G.tar`. Il flasher
finisce con `DONE: ... no errors`; poi `reboot -f` nella shell (`ncat 192.168.7.2 2323`). Per file molto grossi puoi
anche lanciare `xfer-start` nella shell, copiare il `.tar` sul disco USB da 4 GiB `A03XFER` che compare sul PC, espellerlo
e lanciare `xfer-flash` (scrive su 4 GiB vicino alla fine di `userdata`; il filesystem ci si espande sopra al primo avvio).

### 3. Immagine di boot: `AP_BOOT_WDT_A03G.tar`

Torna in download mode, flashalo con Odin (slot AP) e lascia riavviare il telefono. Dopo uno o due minuti:

```
ssh root@192.168.7.2          # password: 1234
```

(Lascia la scheda RNDIS del PC su `192.168.7.1/24`.)

> **Non** flashare l'AP Samsung originale dopo, a meno che tu voglia riavere Android: sovrascrive boot e userdata.

## Primo avvio

- Il filesystem si espande da solo a tutta la partizione (`df -h /` deve mostrare ~50 GB).
- **Cambia la password** (`passwd`): `1234` serve solo per entrare la prima volta.
- L'unica rete è il link USB. Per dare internet al telefono condividi la connessione del PC:
  - PC Linux: `sudo sysctl -w net.ipv4.ip_forward=1 && sudo iptables -t nat -A POSTROUTING -s 192.168.7.0/24 -j MASQUERADE`,
    poi sul telefono `ip route add default via 192.168.7.1 && echo 'nameserver 1.1.1.1' > /etc/resolv.conf`.
  - Windows (Condivisione connessione Internet): cambia l'IP della scheda in `192.168.137.1`. Sul telefono usa
    `ip addr add 192.168.137.2/24 dev usb0 && ip route add default via 192.168.137.1` più la riga `resolv.conf`.
- Sul telefono non c'è gestione dello schermo (vedi [sotto](#schermo-e-desktop-remoto)) e gira solo ssh.

## Wi-Fi (opzionale)

Il chip Wi-Fi richiede i moduli e il firmware Unisoc originali Samsung, quindi è un pacchetto a parte. Il telefono
deve avere internet una volta (vedi sopra) perché `install.sh` installi `network-manager wpasupplicant iw`.

```
scp a03-wifi.tar.gz root@192.168.7.2:
ssh root@192.168.7.2
tar xzf a03-wifi.tar.gz && cd a03-wifi && ./install.sh
nmcli device wifi list
nmcli device wifi connect "NOME_RETE" password "PASSWORD"
```

Log: `/var/log/a03-wifi.log`. Il pacchetto funziona solo con il kernel della stessa release (i moduli sono blob binari
verificati con i CRC esatti dei simboli). `./install.sh --no-boot` non carica il Wi-Fi all'avvio.

## Problemi incontrati e come risolverli

### "No space left" anche se il telefono è vuoto

`df -h` mostra `/` da ~1,5 GB mentre la partizione è di ~50 GB:

```
/dev/mmcblk0p55  1.5G  1.2G  291M  81% /
```

**Causa:** l'immagine del root filesystem è creata piccola (1,5 GB) e scritta in una partizione molto più grande; ext4
mantiene la dimensione originale. **Soluzione:** allargalo a caldo, senza smontare:

```
resize2fs "$(findmnt -no SOURCE /)"
```

L'immagine 1.0 lo fa da sola al primo avvio (`a03-resizefs.service`); il comando manuale serve per le immagini
vecchie. (Sul nostro esemplare la partizione era `/dev/mmcblk0p55`: non dare per scontato che sia uguale sul tuo.)

### Debian parte ma non c'è rete USB / ssh

**Causa (immagini vecchie):** `a03-usb-net` controllava se il gadget USB fosse già agganciato con `[ -s "$G/UDC" ]`,
che su configfs è *sempre vero*, quindi il gadget non si agganciava mai al controller USB e `usb0` non compariva.
**Corretto** in questa release (ora il controllo è `[ -z "$(cat "$G/UDC")" ]`).

Per riparare un'immagine vecchia dalla shell di soccorso (`ncat 192.168.7.2 2323`):

```
P=$(for u in /sys/class/block/*/uevent; do grep -qx PARTNAME=userdata $u && { d=${u%/uevent}; echo /dev/${d##*/}; }; done)
mkdir -p /newroot; mount -t ext4 $P /newroot
sed -i 's|^.*-s "\$G/UDC".*$|[ -z "$(cat "$G/UDC" 2>/dev/null)" ] \&\& echo "$UDC" > "$G/UDC"|' /newroot/usr/local/sbin/a03-usb-net
grep -n UDC /newroot/usr/local/sbin/a03-usb-net
sync; umount /newroot; echo done
```

### Odin fallisce su userdata.img

Se Odin si ferma con `Complete(Write) operation failed` scrivendo `userdata.img` sparse, usa il flasher di soccorso
(`a03d`, porta 1234, vedi passo 2): capisce le immagini sparse e scrive i chunk "don't care" come zeri, così ext4 non
trova sporcizia.

### Bootloop, o il telefono sembra morto

Quello che è successo a noi: una combinazione boot/vbmeta sbagliata faceva morire l'init di primo stadio di Android
(`avb_slot_verify failed`, poi `Attempted to kill the init task!` e riavvio, all'infinito). In seguito il telefono non
dava **nessun segno di vita**: né download mode, né recovery, né ricarica, nulla sul PC.

1. Riprova la download mode (Volume su + Volume giù collegando l'USB) e flasha il **firmware Samsung completo**
   (BL, AP, CP, CSC) con Odin. Ripristina Android e le partizioni originali; poi ricomincia dal passo 1.
2. Se il telefono è completamente morto (procedura avanzata, a tuo rischio): noi lo abbiamo aperto, ricollegato la
   batteria e toccato il **test point (pad PWR/GND)** collegando l'USB. È ripartito in bootloop e poi è entrato in
   download mode, da cui abbiamo rimesso il firmware originale.
3. Per capire perché si è riavviato, avvia la recovery di soccorso e leggi il pstore del kernel:
   `mount -t pstore pstore /sys/fs/pstore && ls /sys/fs/pstore` (`console-ramoops-0`, `dmesg-ramoops-0`).
   Flashare l'AP originale cancella i log di Debian su `userdata`: leggili prima.

### Il telefono si riavviava da solo ogni 5-7 minuti

Con i primi kernel Debian girava circa 5-7 minuti e poi il dispositivo si resettava senza alcun panic. Il kernel di
questa release disabilita il watchdog PMIC (patch in `.github/workflows/kernel.yml`) per affrontare il problema. Se
compili un tuo kernel, tieni quella patch.

### Wi-Fi: manca `wlan0`

Leggi `/var/log/a03-wifi.log` e `dmesg | tail -n 80`. La causa tipica è un kernel con release diversa da quella del
pacchetto. Non abilitare il gruppo `sysv` in `kernel.yml`: cambia i CRC dei simboli e i moduli Wi-Fi originali non si
caricano più (il workflow rifiuta di pubblicare un kernel così).

## Schermo e desktop remoto

**Non** abbiamo pensato allo schermo: il display dell'esemplare di test era distrutto, quindi non si vede nulla e il
pannello non è gestito in alcun modo (non si spegne e non c'è né gestione del display né desktop). Se vuoi una sessione
grafica puoi installare un desktop e usare **xrdp** (RDP) sul link USB o Wi-Fi. Qui non è stato provato. Un limite
incontrato: il backend Xorg di xrdp richiede SysV IPC, che questo kernel non ha (abilitarlo rompe i moduli Wi-Fi
originali, vedi sopra), quindi usa xrdp con una sessione **Xvnc**.

## Compilare tutto da soli

Tutte le build girano su GitHub Actions (niente a mano). Gli input (sorgenti kernel Samsung ed estratto del firmware)
sono nella release stessa: un fork deve solo puntare `INPUTS_REPO` nei workflow alla propria copia della release.

1. Avvia **kernel**. Compila il kernel, carica `Image`, moduli e report CRC, e poi avvia da solo **boot-wdt**
   (`AP_BOOT_WDT_A03G.tar`) e **wifi** (`a03-wifi.tar.gz`).
2. Avvia **recovery** (`AP_REC_KSTOCK_VBSTOCK_A03G.tar`).
3. Avvia **userdata** (`USERDATA_MIN_A03G.tar`).

Struttura: `.github/workflows/` (i cinque workflow), `scripts/` (script di build), `initramfs/` (demone di soccorso
`a03d.c`, `init.sh`, helper di trasferimento USB), `rootfs-overlay/` (file messi nell'immagine Debian), `wifi/` (file
del pacchetto Wi-Fi).

## Note legali

Script e workflow: MIT (vedi `LICENSE`). Il kernel è compilato dalla release open source Samsung (GPL-2.0). Le immagini
contengono anche kernel della recovery originale, `vbmeta`, device tree, firmware e moduli Wi-Fi/BT Samsung, che restano
sotto le condizioni di Samsung. Progetto non ufficiale, senza alcuna garanzia.
