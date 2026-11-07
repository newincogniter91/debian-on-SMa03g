// a03d: rescue server for the Galaxy A03 initramfs/recovery
//  port 2323: shell (sh -i) on the socket
//  port 1234: receives an AP tar (ustar) and writes boot/userdata/vbmeta/dtbo/recovery to the partitions
//              (sparse images included: DONT_CARE chunks are written as zeros so ext4 never sees leftovers)
//  local use: a03d --flash < AP.tar
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define BUFSZ (1 << 20)
static int out_fd = 2;
static unsigned char *buf;
static unsigned char fb[BUFSZ];
static int nerr, nok;
static uint64_t written;

static void say(const char *fmt, ...) {
  char b[512];
  va_list ap;
  va_start(ap, fmt);
  int n = vsnprintf(b, sizeof b, fmt, ap);
  va_end(ap);
  if (n <= 0) return;
  if (n > (int)sizeof b - 1) n = sizeof b - 1;
  if (write(out_fd, b, n) < 0) {}
  int k = open("/dev/kmsg", O_WRONLY);
  if (k >= 0) { if (write(k, b, n) < 0) {} close(k); }
}

static ssize_t rd_full(int fd, void *p, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, (char *)p + got, n - got);
    if (r < 0) { if (errno == EINTR) continue; return -1; }
    if (r == 0) break;
    got += r;
  }
  return got;
}
static int wr_full(int fd, const void *p, size_t n) {
  size_t off = 0;
  while (off < n) {
    ssize_t w = write(fd, (const char *)p + off, n - off);
    if (w < 0) { if (errno == EINTR) continue; return -1; }
    off += w;
  }
  return 0;
}
static void progress(uint64_t add) {
  uint64_t before = written >> 28;
  written += add;
  if ((written >> 28) != before) say("  %llu MB written\n", (unsigned long long)(written >> 20));
}
static int skip(int fd, uint64_t n) {
  while (n) {
    size_t c = n > BUFSZ ? BUFSZ : n;
    if (rd_full(fd, buf, c) != (ssize_t)c) return -1;
    n -= c;
  }
  return 0;
}
static int copy(int fd, int d, uint64_t n) {
  while (n) {
    size_t c = n > BUFSZ ? BUFSZ : n;
    if (rd_full(fd, buf, c) != (ssize_t)c) return -1;
    if (wr_full(d, buf, c)) return -1;
    progress(c);
    n -= c;
  }
  return 0;
}
static int fillw(int d, uint64_t n, const unsigned char *pat) {
  for (int i = 0; i < BUFSZ; i++) fb[i] = pat[i & 3];
  while (n) {
    size_t c = n > BUFSZ ? BUFSZ : n;
    if (wr_full(d, fb, c)) return -1;
    progress(c);
    n -= c;
  }
  return 0;
}
static unsigned le16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static uint32_t le32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }

static int find_part(const char *name, char *dev, size_t sz) {
  const char *td = getenv("A03_TESTDIR");
  if (td) { snprintf(dev, sz, "%s/%s", td, name); return 0; }
  DIR *d = opendir("/sys/class/block");
  if (!d) return -1;
  struct dirent *e;
  char want[128];
  snprintf(want, sizeof want, "PARTNAME=%s", name);
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    char p[512];
    snprintf(p, sizeof p, "/sys/class/block/%s/uevent", e->d_name);
    FILE *f = fopen(p, "r");
    if (!f) continue;
    char line[256];
    int hit = 0;
    while (fgets(line, sizeof line, f)) {
      line[strcspn(line, "\r\n")] = 0;
      if (!strcmp(line, want)) hit = 1;
    }
    fclose(f);
    if (hit) { snprintf(dev, sz, "/dev/%s", e->d_name); closedir(d); return 0; }
  }
  closedir(d);
  return -1;
}

static int allowed(const char *p) {
  static const char *ok[] = {"boot", "userdata", "vbmeta", "dtbo", "recovery", NULL};
  for (int i = 0; ok[i]; i++) if (!strcmp(p, ok[i])) return 1;
  return 0;
}

static int sparse(int fd, int d, const unsigned char *h, uint64_t *rem) {
  unsigned fhs = le16(h + 8), chs = le16(h + 10);
  uint32_t bs = le32(h + 12), tot = le32(h + 20);
  if (fhs < 28 || chs < 12 || bs == 0 || bs % 4) return -1;
  if (fhs > 28) { if (skip(fd, fhs - 28)) return -1; *rem -= fhs - 28; }
  for (uint32_t i = 0; i < tot; i++) {
    unsigned char c[12];
    if (rd_full(fd, c, 12) != 12) return -1;
    *rem -= 12;
    if (chs > 12) { if (skip(fd, chs - 12)) return -1; *rem -= chs - 12; }
    unsigned type = le16(c);
    uint32_t csz = le32(c + 4), tsz = le32(c + 8);
    uint64_t bytes = (uint64_t)csz * bs, dl = tsz - chs;
    if (type == 0xCAC1) {
      if (dl != bytes || copy(fd, d, dl)) return -1;
      *rem -= dl;
    } else if (type == 0xCAC2) {
      unsigned char p[4];
      if (dl != 4 || rd_full(fd, p, 4) != 4) return -1;
      *rem -= 4;
      if (fillw(d, bytes, p)) return -1;
    } else if (type == 0xCAC3) {
      unsigned char z[4] = {0, 0, 0, 0};
      if (fillw(d, bytes, z)) return -1;
    } else if (type == 0xCAC4) {
      if (skip(fd, dl)) return -1;
      *rem -= dl;
    } else {
      say("unknown sparse chunk 0x%x\n", type);
      return -1;
    }
  }
  return 0;
}

// 0 = stream still valid (even if the partition was refused), -1 = broken stream
static int member(int fd, const char *name, uint64_t size) {
  const char *b = name;
  while (!strncmp(b, "./", 2)) b += 2;
  size_t L = strlen(b);
  if (L < 5 || strcmp(b + L - 4, ".img")) { say("skipping %s\n", b); return skip(fd, size); }
  char part[64];
  if (L - 4 >= sizeof part) return skip(fd, size);
  memcpy(part, b, L - 4);
  part[L - 4] = 0;
  if (!allowed(part)) { say("REFUSED %s: partition not in the allowed list\n", b); nerr++; return skip(fd, size); }
  char dev[320];
  if (find_part(part, dev, sizeof dev)) { say("ERROR: partition %s not found\n", part); nerr++; return skip(fd, size); }
  int d = open(dev, O_WRONLY | (getenv("A03_TESTDIR") ? O_CREAT : 0), 0644);
  if (d < 0) { say("ERROR: cannot open %s: %s\n", dev, strerror(errno)); nerr++; return skip(fd, size); }
  say("writing %s to %s (%llu bytes)\n", b, dev, (unsigned long long)size);
  written = 0;
  uint64_t rem = size;
  int rc = 0;
  unsigned char h[28];
  size_t first = size < 28 ? size : 28;
  if (rd_full(fd, h, first) != (ssize_t)first) { close(d); return -1; }
  rem -= first;
  if (first == 28 && le32(h) == 0xED26FF3Au) {
    rc = sparse(fd, d, h, &rem);
  } else {
    if (wr_full(d, h, first)) rc = -1;
    else { rc = copy(fd, d, rem); rem = 0; }
  }
  if (!rc && rem) rc = skip(fd, rem);
  if (rc) { say("ERROR: writing %s was interrupted\n", b); close(d); nerr++; return -1; }
  fsync(d);
  close(d);
  nok++;
  say("ok %s\n", b);
  return 0;
}

static void handle_flash(int fd) {
  out_fd = fd == 0 ? 2 : fd;
  nerr = nok = 0;
  say("ready: receiving the AP tar\n");
  unsigned char hdr[512];
  int zeros = 0;
  for (;;) {
    if (rd_full(fd, hdr, 512) != 512) break;
    int allz = 1;
    for (int i = 0; i < 512; i++) if (hdr[i]) { allz = 0; break; }
    if (allz) { if (++zeros >= 2) break; continue; }
    zeros = 0;
    char nm[101], pre[156], name[300];
    memcpy(nm, hdr, 100); nm[100] = 0;
    memcpy(pre, hdr + 345, 155); pre[155] = 0;
    if (pre[0]) snprintf(name, sizeof name, "%s/%s", pre, nm); else snprintf(name, sizeof name, "%s", nm);
    uint64_t size = 0;
    int i = 124;
    while (i < 136 && hdr[i] == ' ') i++;
    for (; i < 136 && hdr[i] >= '0' && hdr[i] <= '7'; i++) size = size * 8 + (hdr[i] - '0');
    char type = hdr[156];
    if (type == '0' || type == 0) {
      if (member(fd, name, size)) { say("ERROR: stream interrupted or corrupted\n"); nerr++; break; }
    } else if (skip(fd, size)) break;
    uint64_t pad = (512 - size % 512) % 512;
    if (pad && skip(fd, pad)) break;
  }
  sync();
  if (nerr) say("FINISHED WITH ERRORS: %d errors, %d partitions written\n", nerr, nok);
  else say("DONE: %d partitions written, no errors. You can reboot now (reboot -f from the 2323 shell)\n", nok);
}

static int lsock(int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return -1;
  int one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in a;
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_ANY);
  a.sin_port = htons(port);
  if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 2)) { close(s); return -1; }
  return s;
}

int main(int argc, char **argv) {
  buf = malloc(BUFSZ);
  if (!buf) return 1;
  if (argc > 1 && !strcmp(argv[1], "--flash")) { handle_flash(0); return nerr != 0; }
  signal(SIGCHLD, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);
  int s1 = lsock(2323), s2 = lsock(1234);
  if (s1 < 0 || s2 < 0) return 1;
  struct pollfd p[2] = {{s1, POLLIN, 0}, {s2, POLLIN, 0}};
  for (;;) {
    if (poll(p, 2, -1) < 0) continue;
    for (int k = 0; k < 2; k++) {
      if (!(p[k].revents & POLLIN)) continue;
      int c = accept(p[k].fd, NULL, NULL);
      if (c < 0) continue;
      if (fork() == 0) {
        close(s1); close(s2);
        if (k == 0) {
          dup2(c, 0); dup2(c, 1); dup2(c, 2);
          if (c > 2) close(c);
          execl("/bin/sh", "sh", "-i", (char *)0);
          _exit(1);
        }
        handle_flash(c);
        close(c);
        _exit(0);
      }
      close(c);
    }
  }
}
