// Native filesystem adapter. POSIX uses openat + O_NOFOLLOW; Windows uses
// UTF-16 Win32 handles and rejects reparse points before relative operations.
#ifndef _WIN32
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
#else

#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>

#define MC_MAX_PATH 32768
#define MC_MAX_FILE 16777216
static wchar_t root_path[MC_MAX_PATH];
static size_t root_len = 0;
static HANDLE lock_handle = INVALID_HANDLE_VALUE;

static int utf8_wide(const char *value, wchar_t *out, int cap) {
  if (!value || !out || cap <= 0) return -1;
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, out, cap);
  return n > 0 ? n : -1;
}

static int wide_utf8(const wchar_t *value, char *out, int cap) {
  if (!value || !out || cap <= 0) return -1;
  int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, -1, out, cap, NULL, NULL);
  return n > 0 ? n : -1;
}

static int safe_relative(const char *path) {
  if (!path || !path[0] || path[0] == '/' || strchr(path, '\\') || strchr(path, ':')) return -1;
  const char *part = path;
  while (*part) {
    const char *end = strchr(part, '/');
    size_t len = end ? (size_t)(end - part) : strlen(part);
    if (!len || (len == 1 && part[0] == '.') || (len == 2 && part[0] == '.' && part[1] == '.')) return -1;
    if (!end) break;
    part = end + 1;
  }
  return 0;
}

static int join_path(const char *relative, wchar_t *out, int cap) {
  wchar_t part[MC_MAX_PATH];
  if (safe_relative(relative) || utf8_wide(relative, part, MC_MAX_PATH) < 0) return -1;
  for (wchar_t *p = part; *p; ++p) if (*p == L'/') *p = L'\\';
  int n = _snwprintf(out, cap, L"%ls%ls", root_path, part);
  return n >= 0 && n < cap ? 0 : -1;
}

static int no_reparse(const wchar_t *full) {
  wchar_t probe[MC_MAX_PATH];
  if (wcslen(full) >= MC_MAX_PATH) return -1;
  wcscpy(probe, full);
  size_t start = root_len;
  for (size_t i = start; probe[i]; ++i) {
    if (probe[i] != L'\\') continue;
    wchar_t saved = probe[i]; probe[i] = L'\0';
    DWORD attrs = GetFileAttributesW(probe);
    probe[i] = saved;
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return -1;
  }
  DWORD attrs = GetFileAttributesW(full);
  return attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_REPARSE_POINT) ? -1 : 0;
}

static int no_reparse_parent(const wchar_t *full) {
  wchar_t parent[MC_MAX_PATH];
  if (wcslen(full) >= MC_MAX_PATH) return -1;
  wcscpy(parent, full);
  wchar_t *slash = wcsrchr(parent, L'\\');
  if (!slash || slash == parent) return -1;
  *slash = L'\0';
  return no_reparse(parent);
}

static HANDLE open_regular(const wchar_t *full, DWORD access, DWORD share, DWORD disposition) {
  if (no_reparse(full)) return INVALID_HANDLE_VALUE;
  HANDLE h = CreateFileW(full, access, share, NULL, disposition,
    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  if (h == INVALID_HANDLE_VALUE) return h;
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(h, &info) || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    CloseHandle(h); return INVALID_HANDLE_VALUE;
  }
  return h;
}

int mc_root(const char *path) {
  wchar_t candidate[MC_MAX_PATH];
  if (utf8_wide(path, candidate, MC_MAX_PATH) < 0) return -1;
  size_t n = wcslen(candidate);
  while (n > 1 && (candidate[n - 1] == L'\\' || candidate[n - 1] == L'/')) candidate[--n] = L'\0';
  DWORD attrs = GetFileAttributesW(candidate);
  if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) ||
      (attrs & FILE_ATTRIBUTE_REPARSE_POINT) || n + 1 >= MC_MAX_PATH) return -1;
  if (root_len) root_path[root_len - 1] = L'\0';
  wcscpy(root_path, candidate); root_path[n] = L'\\'; root_path[n + 1] = L'\0'; root_len = n + 1;
  return 0;
}

int mc_size(const char *path) {
  wchar_t full[MC_MAX_PATH]; if (join_path(path, full, MC_MAX_PATH)) return -2;
  HANDLE h = open_regular(full, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, OPEN_EXISTING);
  if (h == INVALID_HANDLE_VALUE) return GetLastError() == ERROR_FILE_NOT_FOUND ? -1 : -2;
  LARGE_INTEGER size; int result = -2;
  if (GetFileSizeEx(h, &size) && size.QuadPart <= MC_MAX_FILE) result = (int)size.QuadPart;
  CloseHandle(h); return result;
}

int mc_read(const char *path, unsigned char *buf, int cap) {
  wchar_t full[MC_MAX_PATH]; if (join_path(path, full, MC_MAX_PATH)) return -1;
  HANDLE h = open_regular(full, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, OPEN_EXISTING);
  if (h == INVALID_HANDLE_VALUE) return -1;
  LARGE_INTEGER size; if (!GetFileSizeEx(h, &size) || size.QuadPart > cap || size.QuadPart > MC_MAX_FILE) { CloseHandle(h); return -1; }
  DWORD got = 0, total = 0;
  while (total < (DWORD)size.QuadPart && ReadFile(h, buf + total, (DWORD)size.QuadPart - total, &got, NULL) && got) total += got;
  unsigned char extra; DWORD more = 0; BOOL extra_read = ReadFile(h, &extra, 1, &more, NULL);
  int ok = total == (DWORD)size.QuadPart && extra_read && more == 0;
  CloseHandle(h); return ok ? (int)total : -1;
}

int mc_write(const char *path, const unsigned char *buf, int len) {
  wchar_t full[MC_MAX_PATH], temp[MC_MAX_PATH];
  if (join_path(path, full, MC_MAX_PATH) || no_reparse_parent(full)) return -1;
  if (_snwprintf(temp, MC_MAX_PATH, L"%ls.corridor-tmp", full) < 0) return -1;
  HANDLE h = CreateFileW(temp, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return -1;
  DWORD done = 0, wrote = 0; int ok = 1;
  while (done < (DWORD)len) { if (!WriteFile(h, buf + done, (DWORD)len - done, &wrote, NULL) || !wrote) { ok = 0; break; } done += wrote; }
  if (ok && (!FlushFileBuffers(h) || done != (DWORD)len)) ok = 0;
  CloseHandle(h);
  if (ok && !MoveFileExW(temp, full, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) ok = 0;
  if (!ok) DeleteFileW(temp);
  return ok ? 0 : -1;
}

int mc_mkdir(const char *path) {
  wchar_t full[MC_MAX_PATH]; if (join_path(path, full, MC_MAX_PATH)) return -1;
  if (CreateDirectoryW(full, NULL)) return 0;
  if (GetLastError() == ERROR_ALREADY_EXISTS && no_reparse(full) == 0) return 0;
  return -1;
}

int mc_remove(const char *path) {
  wchar_t full[MC_MAX_PATH]; if (join_path(path, full, MC_MAX_PATH)) return -1;
  if (GetFileAttributesW(full) == INVALID_FILE_ATTRIBUTES && GetLastError() == ERROR_FILE_NOT_FOUND) return 0;
  if (no_reparse(full)) return -1;
  if (DeleteFileW(full) || GetLastError() == ERROR_FILE_NOT_FOUND) return 0;
  return -1;
}

int mc_list(const char *path, unsigned char *buf, int cap) {
  wchar_t dir[MC_MAX_PATH], pattern[MC_MAX_PATH]; if (join_path(path, dir, MC_MAX_PATH) || no_reparse(dir)) return -1;
  if (_snwprintf(pattern, MC_MAX_PATH, L"%ls\\*", dir) < 0) return -1;
  WIN32_FIND_DATAW data; HANDLE find = FindFirstFileW(pattern, &data); if (find == INVALID_HANDLE_VALUE) return -1;
  int used = 0, result = -1;
  do {
    if (!wcscmp(data.cFileName, L".") || !wcscmp(data.cFileName, L"..")) continue;
    if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) { FindClose(find); return -1; }
    char name[MC_MAX_PATH]; int n = wide_utf8(data.cFileName, name, sizeof(name));
    if (n <= 1 || strchr(name, '\n') || used + n + 1 >= cap) { FindClose(find); return -1; }
    buf[used++] = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? 'd' : 'f';
    memcpy(buf + used, name, n - 1); used += n - 1; buf[used++] = '\n';
  } while (FindNextFileW(find, &data));
  result = GetLastError() == ERROR_NO_MORE_FILES ? used : -1; FindClose(find); return result;
}

int mc_lock(void) {
  if (lock_handle != INVALID_HANDLE_VALUE) return -1;
  wchar_t path[MC_MAX_PATH]; if (_snwprintf(path, MC_MAX_PATH, L"%ls.corridor-lock", root_path) < 0) return -1;
  lock_handle = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, NULL);
  if (lock_handle == INVALID_HANDLE_VALUE) return -1;
  return 0;
}
int mc_unlock(void) { if (lock_handle == INVALID_HANDLE_VALUE) return -1; CloseHandle(lock_handle); lock_handle = INVALID_HANDLE_VALUE; return 0; }

int mc_check(const char *path) {
  wchar_t file[MC_MAX_PATH], command[MC_MAX_PATH * 2];
  if (utf8_wide(path, file, MC_MAX_PATH) < 0 || _snwprintf(command, sizeof(command) / sizeof(wchar_t),
      L"moon check --deny-warn --target-dir .corridor/compiler \"%ls\"", file) < 0) return -1;
  STARTUPINFOW startup = { sizeof(startup) }; PROCESS_INFORMATION process = { 0 };
  if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, root_path, &startup, &process)) return -1;
  WaitForSingleObject(process.hProcess, INFINITE); DWORD code = 1; GetExitCodeProcess(process.hProcess, &code);
  CloseHandle(process.hThread); CloseHandle(process.hProcess); return (int)code;
}
#endif
