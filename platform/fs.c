// Native filesystem adapter. POSIX only: openat + O_NOFOLLOW with atomic
// tmp+fsync+rename writes. Cross-platform delivery is the wasm service
// runtime's job (docs/wasm.md); git history keeps the removed Windows branch.
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif
static int root_fd = -1, lock_fd = -1;
int mc_root(const char *path) {
  if (root_fd >= 0) close(root_fd);
  root_fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  return root_fd < 0 ? -1 : 0;
}
static int parent(const char *path, char *leaf) {
  char buf[4096];
  if (strlen(path) >= sizeof(buf) || path[0] == '/' || !path[0]) return -1;
  strcpy(buf, path);
  int fd = dup(root_fd);
  char *save, *part = strtok_r(buf, "/", &save);
  while (part) {
    if (!strcmp(part,".") || !strcmp(part,"..")) { close(fd); return -1; }
    char *next = strtok_r(NULL, "/", &save);
    if (!next) { strcpy(leaf, part); return fd; }
    int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    close(fd); if (child < 0) return -1; fd = child; part = next;
  }
  close(fd); return -1;
}
int mc_size(const char *path) {
  char leaf[4096]; int p = parent(path, leaf); if (p < 0) return errno == ENOENT ? -1 : -2;
  struct stat s; int rc = fstatat(p, leaf, &s, AT_SYMLINK_NOFOLLOW); close(p);
  if (rc < 0) return errno == ENOENT ? -1 : -2;
  return S_ISREG(s.st_mode) && s.st_size <= 16777216 ? (int)s.st_size : -2;
}
// Change signal for the verification memo: size, mtime, ctime, inode and mode
// of the last component, never following symlinks. Callers re-read and re-hash
// whenever it differs, and fall back to a full read when it cannot be produced
// (missing, unsafe, non-regular, or an adapter without stat). Returns the
// number of bytes written (without NUL), or -1.
static int dot_segment(const char *path) {
  const char *p = path;
  while (*p) {
    const char *next = strchr(p, '/');
    size_t n = next ? (size_t)(next - p) : strlen(p);
    if (n == 0 || (n == 1 && p[0] == '.') || (n == 2 && p[0] == '.' && p[1] == '.')) return 1;
    if (!next) break;
    p = next + 1;
  }
  return 0;
}
int mc_signature(const char *path, char *buf, int cap) {
  struct stat s; int rc;
  // Fast path: one fstatat relative to the vault root. Intermediate components
  // may be followed here because this never reads content: a match can only
  // skip a read when it equals the identity recorded by a hardened read, and a
  // mismatch (including any replaced or symlinked target) falls back to the
  // hardened walk below.
  if (root_fd >= 0 && path[0] != '/' && !dot_segment(path)) {
    rc = fstatat(root_fd, path, &s, AT_SYMLINK_NOFOLLOW);
  } else {
    char leaf[4096]; int p = parent(path, leaf);
    if (p < 0) return -1;
    rc = fstatat(p, leaf, &s, AT_SYMLINK_NOFOLLOW); close(p);
  }
  if (rc || !S_ISREG(s.st_mode)) return -1;
#if defined(__APPLE__)
  long long mt = (long long)s.st_mtimespec.tv_sec, mn = (long long)s.st_mtimespec.tv_nsec;
  long long ct = (long long)s.st_ctimespec.tv_sec, cn = (long long)s.st_ctimespec.tv_nsec;
#else
  long long mt = (long long)s.st_mtim.tv_sec, mn = (long long)s.st_mtim.tv_nsec;
  long long ct = (long long)s.st_ctim.tv_sec, cn = (long long)s.st_ctim.tv_nsec;
#endif
  int n = snprintf(buf, (size_t)cap, "%lld:%lld:%lld:%lld:%lld:%llu:%u",
                   (long long)s.st_size, mt, mn, ct, cn,
                   (unsigned long long)s.st_ino, (unsigned)s.st_mode);
  return n > 0 && n < cap ? n : -1;
}
int mc_read(const char *path, unsigned char *buf, int cap) {
  char leaf[4096]; int p = parent(path, leaf); if (p < 0) return -1;
  int fd = openat(p, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK); close(p); if (fd < 0) return -1;
  struct stat s; if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size > 16777216) { close(fd); return -1; }
  int got = 0; while (got < cap) { ssize_t n = read(fd, buf + got, cap - got);
    if (n < 0 && errno == EINTR) continue; if (n <= 0) break; got += n; }
  unsigned char extra; ssize_t more = read(fd, &extra, 1); close(fd);
  return more == 0 ? got : -1;
}
int mc_write(const char *path, const unsigned char *buf, int len) {
  char leaf[4096], temp[4096]; int p = parent(path, leaf); if (p < 0) return -1;
  if (snprintf(temp, sizeof(temp), ".%s.corridor-tmp", leaf) >= sizeof(temp)) { close(p); return -1; }
  int fd = openat(p, temp, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (fd < 0) { close(p); return -1; }
  int done = 0; while (done < len) { ssize_t n = write(fd, buf + done, len - done);
    if (n < 0 && errno == EINTR) continue; if (n <= 0) break; done += n; }
  int rc = done == len ? fsync(fd) : -1; if (close(fd) < 0) rc = -1;
  if (!rc) rc = renameat(p, temp, p, leaf); if (!rc) rc = fsync(p);
  if (rc) unlinkat(p, temp, 0); close(p); return rc;
}
int mc_mkdir(const char *path) {
  char leaf[4096]; int p = parent(path, leaf); if (p < 0) return -1;
  int rc = mkdirat(p, leaf, 0700); if (rc && errno == EEXIST) {
    int fd = openat(p, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    rc = fd < 0 ? -1 : 0; if (fd >= 0) close(fd); }
  if (!rc) rc = fsync(p); close(p); return rc;
}
int mc_remove(const char *path) {
  char leaf[4096]; int p = parent(path, leaf); if (p < 0) return -1;
  int rc = unlinkat(p, leaf, 0); if (rc && errno == ENOENT) rc = 0;
  if (!rc) rc = fsync(p); close(p); return rc;
}
int mc_list(const char *path, unsigned char *buf, int cap) {
  char leaf[4096]; int p = parent(path, leaf); if (p < 0) return -1;
  int fd = openat(p, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW); close(p);
  if (fd < 0) return -1; DIR *dir = fdopendir(fd); if (!dir) { close(fd); return -1; }
  int used = 0; struct dirent *e; errno = 0;
  while ((e = readdir(dir))) {
    if (!strcmp(e->d_name,".") || !strcmp(e->d_name,"..")) continue;
    struct stat s;
    if (fstatat(fd,e->d_name,&s,AT_SYMLINK_NOFOLLOW) || S_ISLNK(s.st_mode)) { closedir(dir); return -1; }
    int n = strlen(e->d_name);
    if (strchr(e->d_name,'\n') || used + n + 2 >= cap) { closedir(dir); return -1; }
    buf[used++] = S_ISDIR(s.st_mode) ? 'd' : 'f'; memcpy(buf+used,e->d_name,n); used+=n; buf[used++]='\n';
  }
  int rc = errno ? -1 : used; closedir(dir); return rc;
}
int mc_lock(void) {
  if (lock_fd >= 0) return -1;
  lock_fd = openat(root_fd,".corridor-lock",O_CREAT|O_RDWR|O_NOFOLLOW,0600);
  if (lock_fd < 0) return -1;
  if (flock(lock_fd,LOCK_EX|LOCK_NB)) { close(lock_fd); lock_fd=-1; return -1; } return 0;
}
int mc_unlock(void) { if(lock_fd < 0) return -1; close(lock_fd); lock_fd=-1; return 0; }
int mc_check(const char *path) {
  pid_t pid = fork(); if (pid < 0) return -1;
  if (!pid) { if(fchdir(root_fd)) _exit(126); dup2(2,1);
    execlp("moon","moon","check","--deny-warn","--target-dir",".corridor/compiler",path,(char*)NULL); _exit(127); }
  int status; while(waitpid(pid,&status,0)<0) { if(errno!=EINTR) return -1; }
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// Resolve the OCR adapter without consulting PATH or the vault. A configured
// path must be absolute; otherwise the only accepted location is the native
// host's own directory (the release package layout). Returning -2 means "not
// configured/disabled" and is a normal fallback, not a failed request.
static int mc_ocr_bin(char *dst, size_t cap) {
  const char *disabled = getenv("MEMORYCORRIDOR_OCR");
  if (disabled && (!strcmp(disabled, "off") || !strcmp(disabled, "0"))) return -2;
  const char *configured = getenv("MEMORYCORRIDOR_OCR_BIN");
  if (configured && configured[0]) {
    if (configured[0] != '/' || strlen(configured) >= cap) return -1;
    if (access(configured, X_OK) != 0) return -2;
    snprintf(dst, cap, "%s", configured);
    return 0;
  }
  char exe[PATH_MAX], resolved[PATH_MAX];
#if defined(__APPLE__)
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) != 0) return -1;
#else
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n <= 0 || n >= (ssize_t)sizeof(exe) - 1) return -1;
  exe[n] = '\0';
#endif
  const char *base = realpath(exe, resolved) ? resolved : exe;
  char *slash = strrchr(base, '/');
  if (!slash) return -1;
  *slash = '\0';
  int n = snprintf(dst, cap, "%s/ocr-adapter", base);
  if (n <= 0 || n >= (int)cap) return -1;
  return access(dst, X_OK) == 0 ? 0 : -2;
}

static long long mc_monotonic_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
  return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// Run the adapter under the vault root with a fixed argv, bounded stdout and a
// hard timeout. The child never sees a shell, PATH lookup, or stdin. Values:
// >=0 bytes written; -1 internal/spawn; -2 adapter unavailable; -3 timeout;
// -4 output overflow; -5 non-zero exit; -6 signal.
int mc_ocr(const char *source, unsigned char *buf, int cap, int timeout_ms) {
  if (!source || !source[0] || source[0] == '/' || dot_segment(source)) return -1;
  char bin[PATH_MAX];
  int available = mc_ocr_bin(bin, sizeof(bin));
  if (available != 0) return available;
  int fds[2];
  if (pipe(fds) != 0) return -1;
  pid_t pid = fork();
  if (pid < 0) { close(fds[0]); close(fds[1]); return -1; }
  if (pid == 0) {
    if (fchdir(root_fd) != 0) _exit(126);
    if (root_fd >= 0) close(root_fd);
    if (lock_fd >= 0) close(lock_fd);
    int devnull = open("/dev/null", O_RDONLY);
    if (devnull >= 0) { dup2(devnull, 0); close(devnull); }
    dup2(fds[1], 1);
    close(fds[0]);
    close(fds[1]);
    char *argv[] = { bin, (char *)source, "--json", (char *)NULL };
    execv(bin, argv);
    _exit(127);
  }
  close(fds[1]);
  int used = 0, timed_out = 0, overflow = 0;
  long long deadline = mc_monotonic_ms() + (timeout_ms > 0 ? timeout_ms : 120000);
  for (;;) {
    long long remaining = deadline - mc_monotonic_ms();
    if (remaining <= 0) { timed_out = 1; break; }
    struct pollfd pfd = { fds[0], POLLIN, 0 };
    int ready = poll(&pfd, 1, (int)remaining);
    if (ready < 0) { if (errno == EINTR) continue; break; }
    if (ready == 0) { timed_out = 1; break; }
    ssize_t got = read(fds[0], buf + used, (size_t)(cap - used));
    if (got < 0) { if (errno == EINTR) continue; break; }
    if (got == 0) break;
    used += (int)got;
    // The output budget is a hard ceiling; do not probe the pipe again, or a
    // child that wrote exactly `cap` bytes without exiting could block us.
    if (used == cap) { overflow = 1; break; }
  }
  close(fds[0]);
  if (timed_out || overflow) kill(pid, SIGKILL);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return -1; }
  if (timed_out) return -3;
  if (overflow) return -4;
  if (!WIFEXITED(status)) return -6;
  if (WEXITSTATUS(status) != 0) return -5;
  return used;
}

int mc_now_utc(char *buf, int cap) {
  const char *override = getenv("MEMORYCORRIDOR_OCR_AT");
  if (override && override[0]) {
    int n = snprintf(buf, (size_t)cap, "%s", override);
    return n > 0 && n < cap ? n : -1;
  }
  time_t now = time(NULL);
  struct tm tm;
  if (!gmtime_r(&now, &tm)) return -1;
  size_t n = strftime(buf, (size_t)cap, "%Y-%m-%dT%H:%M:%SZ", &tm);
  return n > 0 ? (int)n : -1;
}
