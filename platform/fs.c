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
