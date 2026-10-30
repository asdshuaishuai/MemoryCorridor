// Native TCP listener adapter for the loopback web host. POSIX is the
// verified path; the Winsock branch mirrors it but is not yet verified
// against a Windows sysroot. Socket setup is receive/send/close only: the
// web package drives accept per connection and never holds a vault lock.
#ifndef _WIN32
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

int mc_tcp_listen(const char *addr, int port) {
  signal(SIGPIPE, SIG_IGN);
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return -1;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1 ||
      bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 || listen(fd, 64) < 0) {
    close(fd);
    return -1;
  }
  return fd;
}

int mc_tcp_port(int fd) {
  struct sockaddr_in sa;
  socklen_t len = sizeof(sa);
  if (getsockname(fd, (struct sockaddr *)&sa, &len) < 0) return -1;
  return (int)ntohs(sa.sin_port);
}

int mc_tcp_accept(int fd) {
  while (1) {
    int conn = (int)accept(fd, NULL, NULL);
    if (conn >= 0) return conn;
    if (errno != EINTR) return -1;
  }
}

int mc_tcp_recv(int fd, unsigned char *buf, int cap) {
  while (1) {
    ssize_t n = recv(fd, buf, (size_t)cap, 0);
    if (n >= 0) return (int)n;
    if (errno != EINTR) return -1;
  }
}

int mc_tcp_send(int fd, const unsigned char *buf, int len) {
  int done = 0;
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;
#endif
  while (done < len) {
    ssize_t n = send(fd, buf + done, (size_t)(len - done), flags);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += (int)n;
  }
  return 0;
}

void mc_tcp_close(int fd) { close(fd); }

void mc_exit(int code) { exit(code); }
#else

#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdlib.h>
#include <string.h>

static int wsa_ready = 0;

static int wsa_init(void) {
  if (wsa_ready) return 0;
  WSADATA data;
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return -1;
  wsa_ready = 1;
  return 0;
}

int mc_tcp_listen(const char *addr, int port) {
  if (wsa_init()) return -1;
  SOCKET fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd == INVALID_SOCKET) return -1;
  /* Mirrors the POSIX SO_REUSEADDR for parity with the previous adapter.
     Windows semantics differ (it permits re-binding over an active port);
     this branch is not yet verified on a Windows sysroot. */
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof(one));
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1 ||
      bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0 ||
      listen(fd, 64) < 0) {
    closesocket(fd);
    return -1;
  }
  return (int)fd;
}

int mc_tcp_port(int fd) {
  struct sockaddr_in sa;
  int len = sizeof(sa);
  if (getsockname((SOCKET)fd, (struct sockaddr *)&sa, &len) < 0) return -1;
  return (int)ntohs(sa.sin_port);
}

int mc_tcp_accept(int fd) {
  while (1) {
    SOCKET conn = accept((SOCKET)fd, NULL, NULL);
    if (conn != INVALID_SOCKET) return (int)conn;
    if (WSAGetLastError() != WSAEINTR) return -1;
  }
}

int mc_tcp_recv(int fd, unsigned char *buf, int cap) {
  while (1) {
    int n = recv((SOCKET)fd, (char *)buf, cap, 0);
    if (n >= 0) return n;
    if (WSAGetLastError() != WSAEINTR) return -1;
  }
}

int mc_tcp_send(int fd, const unsigned char *buf, int len) {
  int done = 0;
  while (done < len) {
    int n = send((SOCKET)fd, (const char *)(buf + done), len - done, 0);
    if (n < 0) {
      if (WSAGetLastError() == WSAEINTR) continue;
      return -1;
    }
    if (n == 0) return -1;
    done += n;
  }
  return 0;
}

void mc_tcp_close(int fd) { closesocket((SOCKET)fd); }

void mc_exit(int code) { exit(code); }
#endif
