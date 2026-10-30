#!/usr/bin/env python3
"""Thin Unix host for the MemoryCorridor wasm service module.

Embeds the corridor module via wasmtime and implements the `corridor-host`
imports with the same semantics as platform/fs.c: per-component symlink
refusal, atomic tmp+fsync+rename writes, an exclusive flock on
<vault>/.corridor-lock, and a real `moon check` subprocess.

The line protocol on stdin/stdout mirrors the native CLI: one JSON response
line per request, `:exit` or EOF ends the session. All service logic lives in
the wasm module; this file only moves bytes and touches the filesystem.

Usage:
  python3 hosts/wasm-host.py --module _build/wasm/debug/build/wasm/wasm.wasm \
      --root /path/to/vault

Requires a Python interpreter with the `wasmtime` package. Unix-only: the
lock and the compiler subprocess are POSIX facilities, mirroring the native
adapter's scope.
"""
import argparse
import errno
import fcntl
import os
import stat
import subprocess
import sys

MAX_FILE = 16 * 1024 * 1024  # platform/native.mbt refuses anything larger
RETRY_BASE = 8  # wasm/host.mbt status protocol: -(needed+8) means retry
MOON = os.environ.get("MOON_BINARY", "moon")


class Refused(Exception):
    """Path rejected the way platform/fs.c would reject it."""


class Missing(Exception):
    """Final component does not exist (reads map this to None)."""


class Storage:
    def __init__(self, root):
        self.root = os.path.realpath(root)
        if not os.path.isdir(self.root):
            raise SystemExit("vault_directory_required: create root directory first")
        self.lock_fd = None

    # -- path safety -----------------------------------------------------------

    def _components(self, rel):
        if rel.startswith("/") or rel == "":
            raise Refused()
        parts = rel.split("/")
        for part in parts:
            if part in ("", ".", "..") or "\x00" in part:
                raise Refused()
        return parts

    def _walk(self, rel):
        """Open every directory component with O_NOFOLLOW; return (fd, leaf).

        ENOENT anywhere (including a missing intermediate directory) raises
        Missing — the native adapter resolves the whole path with one openat,
        so a pre-write probe of a not-yet-existing page reads as absent, not
        refused. ENOTDIR/ELOOP raise Refused."""
        parts = self._components(rel)
        try:
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError as e:
            raise Missing() if e.errno == errno.ENOENT else Refused()
        try:
            for part in parts[:-1]:
                try:
                    inner = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                except FileNotFoundError:
                    raise Missing()
                except OSError as e:
                    raise Refused()
                os.close(fd)
                fd = inner
            return fd, parts[-1]
        except Missing:
            raise
        except Refused:
            raise
        except BaseException:
            os.close(fd)
            raise

    def _open_leaf(self, rel, flags):
        fd, leaf = self._walk(rel)
        try:
            ffd = os.open(leaf, flags | os.O_NOFOLLOW, dir_fd=fd)
        except FileNotFoundError:
            os.close(fd)
            raise Missing()
        except OSError as e:
            os.close(fd)
            raise Refused()
        except BaseException:
            os.close(fd)
            raise
        return fd, ffd

    # -- corridor-host operations ---------------------------------------------
    # Each returns (status, payload); status >= 0 is a byte count for the
    # buffer imports or 0 for plain ok, -3 missing, -1 refused.

    def read(self, rel):
        try:
            fd, ffd = self._open_leaf(rel, os.O_RDONLY)
        except Missing:
            return (-3, b"")  # native: size == -1 means the file is absent
        except (Refused, NotADirectoryError):
            raise Refused()
        try:
            info = os.fstat(ffd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_FILE:
                raise Refused()
            data = b""
            while len(data) < info.st_size:
                chunk = os.read(ffd, info.st_size - len(data))
                if not chunk:
                    break
                data += chunk
            return (len(data), data)
        finally:
            os.close(ffd)
            os.close(fd)

    def write(self, rel, data):
        if len(data) > MAX_FILE:
            raise Refused()
        fd, leaf = self._walk(rel)
        try:
            tmp = "." + leaf + ".corridor-tmp"
            ffd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            try:
                os.write(ffd, data)
                os.fsync(ffd)
            finally:
                os.close(ffd)
            os.rename(tmp, leaf, src_dir_fd=fd, dst_dir_fd=fd)
            try:
                os.fsync(fd)
            except OSError:
                pass
            return (0, b"")
        finally:
            os.close(fd)

    def mkdir(self, rel):
        fd, leaf = self._walk(rel)
        try:
            try:
                os.mkdir(leaf, dir_fd=fd)
            except FileExistsError:
                pass  # platform/native.mbt mkdirs re-runs must stay idempotent
            return (0, b"")
        except OSError:
            return (-1, b"")
        finally:
            os.close(fd)

    def remove(self, rel):
        fd, leaf = self._walk(rel)
        try:
            try:
                os.unlink(leaf, dir_fd=fd)
            except IsADirectoryError:
                os.rmdir(leaf, dir_fd=fd)
            return (0, b"")
        except OSError:
            return (-1, b"")
        finally:
            os.close(fd)

    def list(self, rel):
        fd, leaf = self._walk(rel)
        try:
            dfd = os.open(leaf, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
        except OSError:
            raise Refused()  # missing or not a directory
        try:
            lines = []
            for entry in os.scandir(dfd):
                kind = "d" if entry.is_dir(follow_symlinks=False) else "f"
                lines.append(kind + entry.name)
            lines.sort()
            return (0, "\n".join(lines).encode("utf-8"))
        finally:
            os.close(dfd)
            os.close(fd)

    def check(self, rel):
        # platform/fs.c: fork + fchdir(root) + execlp("moon", "check",
        # "--deny-warn", "--target-dir", ".corridor/compiler", path)
        try:
            proc = subprocess.run(
                [MOON, "check", "--deny-warn", "--target-dir", ".corridor/compiler", rel],
                cwd=self.root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return (proc.returncode, b"")
        except OSError:
            return (1, b"")

    def lock(self):
        if self.lock_fd is not None:
            return (0, b"")  # one held lock per process, like fs.c's static fd
        fd = os.open(os.path.join(self.root, ".corridor-lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return (-1, b"")
        self.lock_fd = fd
        return (0, b"")

    def unlock(self):
        if self.lock_fd is not None:
            try:
                fcntl.flock(self.lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(self.lock_fd)
                self.lock_fd = None
        return (0, b"")


def serve(module_path, root):
    from wasmtime import Engine, Store, Module, Linker, Func, FuncType, ValType

    storage = Storage(root)
    engine = Engine()
    module = Module.from_file(engine, module_path)
    store = Store(engine)
    linker = Linker(engine)

    holder = {}

    def mem_read(ptr, length):
        return bytes(holder["memory"].read(store, ptr, ptr + length))

    def mem_write(ptr, data):
        holder["memory"].write(store, data, ptr)

    def buffered(op):
        def call(path_ptr, path_len, res_ptr, res_cap):
            try:
                status, data = op(mem_read(path_ptr, path_len).decode("utf-8"))
            except Refused:
                return -1
            except (UnicodeDecodeError, Missing):
                return -3
            if status < 0:
                return status
            if len(data) > res_cap:
                return -(len(data) + RETRY_BASE)
            if data:
                mem_write(res_ptr, data)
            return len(data)
        return call

    def plain(op):
        def call(path_ptr, path_len):
            try:
                status, _ = op(mem_read(path_ptr, path_len).decode("utf-8"))
            except Refused:
                return -1
            except (UnicodeDecodeError, Missing):
                return -1
            return status
        return call

    i32 = ValType.i32()
    defs = [
        ("storage_read", [i32] * 4, buffered(storage.read)),
        ("storage_write", [i32] * 4, lambda p, pl, d, dl: plain(lambda rel: storage.write(rel, mem_read(d, dl)))(p, pl)),
        ("storage_mkdir", [i32] * 2, plain(storage.mkdir)),
        ("storage_remove", [i32] * 2, plain(storage.remove)),
        ("storage_list", [i32] * 4, buffered(storage.list)),
        ("storage_check", [i32] * 2, plain(storage.check)),
        ("storage_lock", [], lambda: storage.lock()[0]),
        ("storage_unlock", [], lambda: storage.unlock()[0]),
    ]
    for name, params, func in defs:
        linker.define(store, "corridor-host", name,
                      Func(store, FuncType(params, [i32]), func))

    instance = linker.instantiate(store, module)
    exports = instance.exports(store)
    holder["memory"] = exports["memory"]

    stdin = sys.stdin.buffer
    while True:
        line = stdin.readline()
        if not line:
            break
        request = line.rstrip(b"\n")
        if request == b":exit":
            break
        # Segmented request load: the module appends chunks, so text-carrying
        # ops (backfill, drafts) reach the same 16 MiB ceiling as single files.
        exports["input_reset"](store)
        for offset in range(0, len(request), 1024 * 1024):
            chunk = request[offset:offset + 1024 * 1024]
            ptr = exports["scratch"](store, len(chunk))
            mem_write(ptr, chunk)
            if exports["input_load"](store, ptr, len(chunk)) != 0:
                break  # overflow flagged; service_execute reports the envelope
        count = exports["service_execute"](store)
        if count is None or count < 0:
            sys.stdout.buffer.write(b'{"ok":false,"error":"service_failed"}\n')
        else:
            out = exports["output_ptr"](store)
            sys.stdout.buffer.write(bytes(holder["memory"].read(store, out, out + count)) + b"\n")
        sys.stdout.buffer.flush()
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--module", required=True, help="path to the corridor .wasm module")
    parser.add_argument("--root", required=True, help="vault directory the module operates on")
    args = parser.parse_args()
    sys.exit(serve(args.module, args.root))


if __name__ == "__main__":
    main()
