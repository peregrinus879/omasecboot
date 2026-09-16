#!/usr/bin/python
"""Bounded, read-only publication context observation. Invoke with python -I -S.

This is an internal observation interface, not recovery or input-discovery authority.
The caller retains root/ESP/public-certificate custody and joins the returned paths
with its admitted native context. Live identifiers never enter the context body.

Acquisition contracts: btrfs-progs v7.1 libbtrfsutil/python/subvolume.c and
libbtrfsutil/subvolume.c; util-linux v2.42.3 misc-utils/blkid.c and
libblkid/src/partitions/partitions.c. blkid opens a supplied /proc/self/fd/N and
uses its block devno for partition details. It also opens the parental disk;
the inventory holds and rechecks that relationship around each partition probe.
Actual mounted Btrfs/FAT and device-FD probing need the disposable guest gates.
"""

import sys

# The CLI deliberately uses -I -S; also suppress cache creation by subsequent
# standard-library imports. Loading the stock extension never processes .pth.
sys.dont_write_bytecode = True

import os

# -I -S governs interpreter startup, not libraries' direct os.environ lookups.
# CPython 3.14 sysconfig._get_sysconfigdata() consumes both
# _PYTHON_SYSCONFIGDATA_NAME and _PYTHON_SYSCONFIGDATA_PATH and can exec the
# selected module. Establish the whole helper environment before importing
# sysconfig or any other environment-sensitive library, not just before the
# extension's ownership checks. The launcher separately sanitizes startup.
HELPER_ENV = {"LC_ALL": "C", "PATH": "/usr/bin", "HOME": "/nonexistent",
              "OPENSSL_CONF": "/dev/null", "BLKID_CONF": "/dev/null"}
os.environ.clear()
os.environ.update(HELPER_ENV)

import base64
import binascii
import collections
import ctypes
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import json
import re
import selectors
import signal
import stat
import subprocess
import sysconfig
import time
import types
import uuid


FORMAT = "omasecboot-publication-context"
ESP_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LAST_FREE = (1 << 64) - 256
MAX_PATH = 4096
MAX_MOUNTS = 8192
MAX_MOUNT_BYTES = 2 * 1024 * 1024
MAX_DEVICES = 1024
MAX_TOTAL_BYTES = 32 * 1024 * 1024
MAX_CERT_BYTES = 128 * 1024
MAX_COMMAND_BYTES = 128 * 1024
MAX_STDERR_BYTES = 8192
MAX_RESULT_BYTES = 32 * 1024
COMMAND_SECONDS = 5
TOTAL_SECONDS = 60
CLEANUP_SECONDS = 0.25
GUARD_DRAIN_SECONDS = 0.5
TAGS = ("TYPE", "UUID", "PART_ENTRY_SCHEME", "PART_ENTRY_UUID", "PART_ENTRY_TYPE")
NON_GPT_SCHEMES = frozenset(("aix", "sgi", "sun", "dos", "mac", "ultrix",
                             "bsd", "unixware", "solaris", "minix", "atari"))
UUID_RE = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
DECIMAL_RE = re.compile(r"0|[1-9][0-9]{0,19}")
OPEN_READ = os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)


def close_inherited_fds(keep):
    """Close this process's irrelevant copies, never unlock a shared OFD.

    close_range covers even FDs above a subsequently lowered RLIMIT_NOFILE,
    without enumerating procfs or opening any host descriptor inventory.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    close_range = libc.close_range
    close_range.argtypes = (ctypes.c_uint, ctypes.c_uint, ctypes.c_int)
    close_range.restype = ctypes.c_int
    first = 3
    for fd in sorted(set(keep) | {0, 1, 2}):
        if fd < first:
            continue
        if first < fd:
            require(close_range(first, fd - 1, 0) == 0, "supervisor", "descriptor-prune")
        first = fd + 1
    require(close_range(first, 0xffffffff, 0) == 0, "supervisor", "descriptor-prune")


def supplied_fds(args):
    return set() if args is None else {args[name] for name in ("root_fd", "esp_fd", "certificate_fd")}


def arm_parent_death(parent_pid):
    """Kernel backstop for an unexpected guardian/worker death, including exec.

    The guardian's lifeline normally cleans the entire worker process group.
    This backstop covers its direct worker and each fixed command if the
    guardian itself dies. Recheck getppid after arming to close the fork race.
    """
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = libc.prctl
    prctl.argtypes = (ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong)
    prctl.restype = ctypes.c_int
    if prctl(1, signal.SIGKILL, 0, 0, 0) != 0 or os.getppid() != parent_pid:
        os._exit(125)


def reset_child_signals():
    for signum in (*TERMINATION_SIGNALS, signal.SIGCHLD):
        signal.signal(signum, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, TERMINATION_SIGNALS)


class Incomplete(Exception):
    """Only fixed operation/code literals may cross the CLI boundary."""

    def __init__(self, operation, code):
        super().__init__(operation, code)
        self.operation = operation
        self.code = code


def require(condition, operation, code):
    if not condition:
        raise Incomplete(operation, code)


def safe_text(value):
    return (type(value) is str and bool(value) and
            all(ord(c) >= 32 and ord(c) != 127 and not 0x80 <= ord(c) <= 0x9f
                and not 0xd800 <= ord(c) <= 0xdfff for c in value))


def canonical_path(value):
    require(safe_text(value) and len(value.encode("utf-8")) <= MAX_PATH and
            value.startswith("/") and (value == "/" or
            all(p not in ("", ".", "..") for p in value[1:].split("/"))) and
            len(value.split("/")) <= 128, "arguments", "path")
    return value


def beneath(path, parent):
    return path != parent and path.startswith(parent.rstrip("/") + "/")


def decimal(value, operation, maximum=(1 << 64) - 1):
    require(type(value) is str and DECIMAL_RE.fullmatch(value) is not None,
            operation, "number")
    result = int(value)
    require(result <= maximum, operation, "number")
    return result


def uuid_text(value, operation, allow_zero=False):
    require(type(value) is str and UUID_RE.fullmatch(value) is not None,
            operation, "uuid")
    value = value.lower()
    require(allow_zero or uuid.UUID(value).int != 0, operation, "uuid")
    return value


def devnum(value):
    require(type(value) is str and value.count(":") == 1, "coverage", "devnum")
    major, minor = value.split(":")
    return (decimal(major, "coverage", (1 << 20) - 1),
            decimal(minor, "coverage", (1 << 20) - 1))


def identity(st):
    return st.st_dev, st.st_ino, st.st_mode, st.st_uid, st.st_gid, st.st_rdev


def file_identity(st):
    return identity(st) + (st.st_size, st.st_mtime_ns, st.st_ctime_ns)


def controlled(st, kind, operation):
    require(stat.S_IFMT(st.st_mode) == kind and st.st_uid == 0 and
            not st.st_mode & (0o002 if kind == stat.S_IFBLK else 0o022), operation, "object")


def parse_args(argv):
    if argv == ["--probe-api"]:
        return None
    keys = {"--root-fd", "--esp-fd", "--root-path", "--esp-path",
            "--config-path", "--certificate-fd"}
    require(len(argv) == 12, "arguments", "framing")
    args = {}
    for key, value in zip(argv[::2], argv[1::2]):
        require(key in keys and key not in args, "arguments", "framing")
        args[key] = value
    require(set(args) == keys, "arguments", "framing")
    result = {key[2:].replace("-", "_"): value for key, value in args.items()}
    for key in ("root_fd", "esp_fd", "certificate_fd"):
        result[key] = decimal(result[key], "arguments", (1 << 20) - 1)
        require(result[key] >= 3, "arguments", "descriptor")
    require(len({result[k] for k in ("root_fd", "esp_fd", "certificate_fd")}) == 3,
            "arguments", "descriptor")
    for key in ("root_path", "esp_path", "config_path"):
        canonical_path(result[key])
    require(beneath(result["config_path"], result["esp_path"]) and
            result["root_path"] != result["esp_path"], "arguments", "scope")
    return result


Mount = collections.namedtuple("Mount", "id parent device root path kind source")


def parse_fdinfo(data):
    # The observed directory and ordinary sysfs-file FDs use these four kernel
    # fields, not the variable records of anon-inode/event descriptors.
    require(type(data) is bytes and len(data) <= 16384 and data.endswith(b"\n"),
            "mounts", "fdinfo")
    rows = data.split(b"\n")[:-1]
    fields = {}
    for row in rows:
        key, separator, value = row.partition(b":\t")
        require(separator and key in (b"pos", b"flags", b"mnt_id", b"ino") and
                key not in fields, "mounts", "fdinfo")
        fields[key] = value
    require(set(fields) == {b"pos", b"flags", b"mnt_id", b"ino"} and
            re.fullmatch(rb"-?(?:0|[1-9][0-9]{0,19})", fields[b"pos"]) is not None and
            re.fullmatch(rb"[0-7]{1,12}", fields[b"flags"]) is not None,
            "mounts", "fdinfo")
    mid = decimal(fields[b"mnt_id"].decode("ascii"), "mounts")
    inode = decimal(fields[b"ino"].decode("ascii"), "mounts")
    require(mid > 0 and inode > 0, "mounts", "fdinfo")
    return mid, inode


def mount_unescape(value):
    require(re.search(r"\\(?!040|011|012|134)", value) is None, "mounts", "escape")
    return re.sub(r"\\(040|011|012|134)", lambda m: chr(int(m[1], 8)), value)


def parse_mountinfo(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_MOUNT_BYTES and
            data.endswith(b"\n"), "mounts", "framing")
    lines = data.decode("utf-8", "surrogateescape").split("\n")[:-1]
    require(len(lines) <= MAX_MOUNTS, "mounts", "limit")
    result = {}
    for line in lines:
        fields = line.split(" ")
        require(len(line) <= 16384 and len(fields) >= 10 and "" not in fields and
                fields.count("-") == 1, "mounts", "framing")
        split = fields.index("-")
        require(split >= 6 and len(fields) == split + 4, "mounts", "framing")
        # Framing/control tokens are checked independently of opaque path
        # fields. Kernel paths can contain literal C0/DEL as well as non-UTF8
        # bytes; selected paths alone must satisfy canonical_path().
        # proc_namespace emits ro/rw before its optional comma-prefixed flags.
        # Filesystem-specific option payloads may themselves contain opaque
        # names, so validate their framing head rather than their whole value.
        require(re.fullmatch(r"(?:ro|rw)(?:,[!-~]+)?", fields[5]) is not None and
                (fields[-1] in ("ro", "rw") or
                 (fields[-1].startswith(("ro,", "rw,")) and len(fields[-1]) > 3)),
                "mounts", "framing")
        mid = decimal(fields[0], "mounts")
        parent = decimal(fields[1], "mounts")
        require(mid > 0 and parent > 0 and mid not in result, "mounts", "identity")
        root, path = (mount_unescape(v) for v in fields[3:5])
        # Unselected kernel paths remain opaque, including non-UTF8 names and
        # escaped controls. Selected authority paths are checked separately.
        require(root.startswith("/") and path.startswith("/"), "mounts", "path")
        kind = fields[split + 1]
        require(re.fullmatch(r"[a-zA-Z0-9_.-]+", kind) is not None,
                "mounts", "type")
        for optional in fields[6:split]:
            require(re.fullmatch(r"[a-z_]+(?::[0-9]+)?", optional) is not None,
                    "mounts", "optional")
        result[mid] = Mount(mid, parent, devnum(fields[2]), root, path, kind,
                            mount_unescape(fields[split + 2]))
    return result


def select_mounts(mounts, root_id, esp_id, root_path, esp_path):
    require(root_id in mounts and esp_id in mounts and root_id != esp_id,
            "mounts", "missing")
    root, esp = mounts[root_id], mounts[esp_id]
    require(root.path == root_path and esp.path == esp_path and esp.root == "/" and
            esp.kind == "vfat", "mounts", "scope")
    # Fresh canonical opens already select the visible mount IDs. A covered
    # lower mount at the same pathname, and children of that lower mount, do
    # not belong to the selected ESP. Every selected descendant necessarily
    # starts with one direct child edge, so no global pathname/ancestry walk is
    # needed (or an unrelated mount graph's equality imposed).
    require(not any(row.id != esp_id and row.parent == esp_id for row in mounts.values()),
            "mounts", "esp-child")
    for selected in (root, esp):
        seen = set()
        cursor = selected
        while cursor.parent in mounts and cursor.parent != cursor.id:
            require(cursor.id not in seen, "mounts", "cycle")
            seen.add(cursor.id)
            cursor = mounts[cursor.parent]
        canonical_path(selected.path)
        canonical_path(selected.root)
        canonical_path(selected.source)
    return root, esp


def parse_uevent(data):
    """Extract only authority fields from bounded kernel newline records.

    PARTNAME and other unused values may contain arbitrary label bytes. They
    are never decoded or retained. Literal newlines create records, so an
    injected authority key is still a duplicate or a checked mismatch; an
    escaped newline is never interpreted as framing or manufactured authority.
    """
    require(type(data) is bytes and 0 < len(data) <= 8192 and data.endswith(b"\n"),
            "coverage", "uevent")
    required = {b"MAJOR", b"MINOR", b"DEVNAME", b"DEVTYPE"}
    authority = required | {b"PARTN"}
    fields = {}
    unused_value = False
    for line in data.split(b"\n")[:-1]:
        key, separator, value = line.partition(b"=")
        if key not in authority:
            # A literal newline in an unused label can produce continuation
            # bytes that are not another KEY=value record. Ignore them only
            # in that unused-value scope; every authority-looking record is
            # still checked first, regardless of its apparent label origin.
            if separator and re.fullmatch(rb"[A-Z0-9_]+", key) is not None:
                unused_value = True
            else:
                require(unused_value, "coverage", "uevent")
            continue
        unused_value = False
        name = key.decode("ascii")
        require(separator and name not in fields and value and all(32 <= c <= 126 for c in value),
                "coverage", "uevent-authority")
        fields[name] = value.decode("ascii")
    require({key.decode("ascii") for key in required} <= fields.keys(),
            "coverage", "uevent-authority")
    devnum(fields["MAJOR"] + ":" + fields["MINOR"])
    canonical_path("/dev/" + fields["DEVNAME"])
    require(fields["DEVTYPE"] in ("disk", "partition"), "coverage", "classification")
    if "PARTN" in fields:
        require(fields["DEVTYPE"] == "partition" and decimal(fields["PARTN"], "coverage") > 0,
                "coverage", "partition")
    return fields


def parse_export(data, device_path):
    require(type(data) is bytes and 0 < len(data) <= MAX_COMMAND_BYTES and
            data.endswith(b"\n") and all(32 <= c <= 126 or c == 10 for c in data),
            "device-probe", "framing")
    lines = data.decode("ascii", "strict").splitlines()
    require(1 <= len(lines) <= len(TAGS) + 1 and
            lines[0] == "DEVNAME=" + device_path, "device-probe", "framing")
    result = {}
    for line in lines[1:]:
        key, separator, value = line.partition("=")
        require(separator and key in TAGS and key not in result and
                re.fullmatch(r"[A-Za-z0-9_.:+-]{1,128}", value) is not None,
                "device-probe", "framing")
        result[key] = value
    require(bool(result), "device-probe", "missing")
    return result


def partition_identity(tags):
    scheme = tags.get("PART_ENTRY_SCHEME")
    if scheme == "gpt":
        return (scheme, uuid_text(tags.get("PART_ENTRY_UUID"), "coverage"),
                uuid_text(tags.get("PART_ENTRY_TYPE"), "coverage"))
    require(scheme in NON_GPT_SCHEMES, "coverage", "unknown-scheme")
    # Known direct partition-table classification is required even for a
    # partition without a filesystem; absence of a UUID is not classification.
    require(bool(tags.get("PART_ENTRY_TYPE")), "coverage", "missing-type")
    return scheme, tags.get("PART_ENTRY_UUID"), tags["PART_ENTRY_TYPE"]


def unique_esp(selected_device, tags, partitions):
    part = partition_identity(tags)
    require(part[0] == "gpt" and part[2] == ESP_GUID and tags.get("TYPE") == "vfat",
            "esp", "type")
    fat_id = tags.get("UUID")
    require(type(fat_id) is str and re.fullmatch(r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}",
                                               fat_id) is not None, "esp", "uuid")
    require(selected_device in partitions and partitions[selected_device] == part,
            "coverage", "selected-missing")
    matches = [device for device, item in partitions.items()
               if item[0] == "gpt" and item[1] == part[1]]
    require(matches == [selected_device], "coverage", "duplicate-partuuid")
    return {"partition_scheme": "gpt", "partition_uuid": part[1],
            "partition_type": ESP_GUID, "filesystem_type": "vfat",
            "filesystem_uuid": fat_id.upper()}


def btrfs_identity(module, fd, inode):
    require(inode == 256, "root", "directory-bind-incomplete")
    observed = module.subvolume_id(fd)
    require(type(observed) is int and (observed == 5 or 256 <= observed <= LAST_FREE),
            "btrfs", "id")
    info = module.subvolume_info(fd, observed)
    require(type(info) is module.SubvolumeInfo and type(info.id) is int and
            info.id == observed and type(info.parent_id) is int and
            0 <= info.parent_id <= LAST_FREE and type(info.uuid) is bytes and
            len(info.uuid) == 16, "btrfs", "metadata")
    own = uuid.UUID(bytes=info.uuid)
    if observed != 5:
        require((info.parent_id == 5 or 256 <= info.parent_id <= LAST_FREE) and
                own.int != 0, "btrfs", "orphan-or-uuid")
    return {"kind": "top-level" if observed == 5 else "subvolume",
            "id": str(observed), "uuid": str(own) if own.int else None}


def pem_der(data):
    require(type(data) is bytes and 0 < len(data) <= MAX_CERT_BYTES,
            "certificate", "limit")
    match = re.fullmatch(rb"[ \t\r\n]*-----BEGIN CERTIFICATE-----\r?\n"
                         rb"([A-Za-z0-9+/=\r\n]+)"
                         rb"-----END CERTIFICATE-----[ \t\r\n]*", data)
    require(match is not None, "certificate", "pem")
    encoded = match[1].replace(b"\r", b"").replace(b"\n", b"")
    try:
        der = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise Incomplete("certificate", "base64") from None
    require(bool(der) and base64.b64encode(der) == encoded, "certificate", "base64")
    return der


class System:
    """Hardware/command seams are replaced only by the external fixture tests."""

    def __init__(self):
        self.bytes = 0
        self.deadline = time.monotonic() + TOTAL_SECONDS
        self.owned_fds = []

    def close(self):
        for fd in reversed(self.owned_fds):
            os.close(fd)
        self.owned_fds.clear()

    def charge(self, size):
        self.bytes += size
        require(self.bytes <= MAX_TOTAL_BYTES, "acquisition", "byte-limit")
        require(time.monotonic() < self.deadline, "acquisition", "timeout")

    def read_fd(self, fd, limit, operation, positional=False):
        chunks = []
        offset = 0
        while True:
            self.charge(0)
            size = min(16384, limit + 1 - offset)
            data = os.pread(fd, size, offset) if positional else os.read(fd, size)
            self.charge(len(data))
            if not data:
                break
            chunks.append(data)
            offset += len(data)
            require(offset <= limit, operation, "byte-limit")
        return b"".join(chunks)

    def open_canonical(self, path, kind, operation, base_fd=None):
        """No symlinks, including ancestors. The returned FD is helper-owned."""
        canonical_path(path)
        current = os.open("/", OPEN_READ | os.O_DIRECTORY) if base_fd is None else os.dup(base_fd)
        try:
            controlled(os.fstat(current), stat.S_IFDIR, operation)
            parts = [] if path == "/" else path[1:].split("/")
            for i, part in enumerate(parts):
                expected = kind if i == len(parts) - 1 else stat.S_IFDIR
                flags = OPEN_READ | (os.O_DIRECTORY if expected == stat.S_IFDIR else 0)
                new = os.open(part, flags, dir_fd=current)
                os.close(current)
                current = new
                controlled(os.fstat(current), expected, operation)
            controlled(os.fstat(current), kind, operation)
            return current
        except BaseException:
            os.close(current)
            raise

    def resolve_owned(self, path, operation, base_fd=None):
        """Resolve owned links, rooted at base_fd for the selected machine ID.

        Absolute symlink targets in a guest root remain inside that root. Each
        link and containing directory is checked; no outside fallback exists.
        The final canonical open independently checks every resolved ancestor.
        """
        canonical_path(path)
        todo = path[1:].split("/") if path != "/" else []
        parts = []
        links = 0
        while todo:
            part = todo.pop(0)
            if part in ("", "."):
                continue
            if part == "..":
                require(bool(parts), operation, "link-scope")
                parts.pop()
                continue
            parent = self.open_canonical("/" + "/".join(parts), stat.S_IFDIR,
                                         operation, base_fd)
            try:
                st = os.stat(part, dir_fd=parent, follow_symlinks=False)
                if stat.S_ISLNK(st.st_mode):
                    require(st.st_uid == 0, operation, "link-owner")
                    target = os.readlink(part, dir_fd=parent)
                    require(identity(st) == identity(os.stat(part, dir_fd=parent,
                                                           follow_symlinks=False)),
                            operation, "link-drift")
                    links += 1
                    require(links <= 32 and safe_text(target) and
                            len(target.encode("utf-8")) <= MAX_PATH,
                            operation, "link-limit")
                    if target.startswith("/"):
                        parts.clear()
                    todo = target.split("/") + todo
                else:
                    parts.append(part)
            finally:
                os.close(parent)
            require(len(todo) + len(parts) <= 128, operation, "path-limit")
        return canonical_path("/" + "/".join(parts))

    def read_path(self, path, limit, operation):
        # proc/self is the one deliberate kernel magic-link exception.
        fd = os.open(path, OPEN_READ)
        try:
            controlled(os.fstat(fd), stat.S_IFREG, operation)
            return self.read_fd(fd, limit, operation)
        finally:
            os.close(fd)

    def mount_id(self, fd):
        before = identity(os.fstat(fd))
        data = self.read_path("/proc/self/fdinfo/" + str(fd), 16384, "mounts")
        mid, _ = parse_fdinfo(data)
        # fstat's filesystem-reported inode is the canonical-open join. fdinfo
        # reports the VFS inode; filesystems may override the getattr value.
        require(before == identity(os.fstat(fd)), "mounts", "fdinfo-drift")
        return mid

    def mounts(self):
        return parse_mountinfo(self.read_path("/proc/self/mountinfo", MAX_MOUNT_BYTES,
                                             "mounts"))

    def namespace(self):
        fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
        try:
            st = os.fstat(fd)
            require(stat.S_ISREG(st.st_mode), "namespace", "type")
            return st.st_dev, st.st_ino
        finally:
            os.close(fd)

    def bind_directory(self, fd, path):
        st = os.fstat(fd)
        controlled(st, stat.S_IFDIR, "custody")
        fresh = self.open_canonical(path, stat.S_IFDIR, "custody")
        try:
            mid = self.mount_id(fd)
            require(identity(st) == identity(os.fstat(fresh)) and
                    self.mount_id(fresh) == mid, "custody", "path-drift")
            return identity(st), mid
        finally:
            os.close(fresh)

    def configuration(self, path, esp_id):
        parent, leaf = path.rsplit("/", 1)
        fd = self.open_canonical(parent or "/", stat.S_IFDIR, "configuration")
        try:
            require(self.mount_id(fd) == esp_id, "configuration", "mount")
            try:
                st = os.stat(leaf, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return
            controlled(st, stat.S_IFREG, "configuration")
        finally:
            os.close(fd)

    def machine_id(self, root_fd):
        path = self.resolve_owned("/etc/machine-id", "machine-id", root_fd)
        fd = self.open_canonical(path, stat.S_IFREG, "machine-id", root_fd)
        try:
            st = os.fstat(fd)
            require(st.st_size in (32, 33), "machine-id", "size")
            before = file_identity(st)
            data = self.read_fd(fd, 33, "machine-id", positional=True)
            require(len(data) == st.st_size and before == file_identity(os.fstat(fd)) and
                    self.resolve_owned("/etc/machine-id", "machine-id", root_fd) == path,
                    "machine-id", "drift")
            fresh = self.open_canonical(path, stat.S_IFREG, "machine-id", root_fd)
            try:
                require(before == file_identity(os.fstat(fresh)), "machine-id", "drift")
            finally:
                os.close(fresh)
        finally:
            os.close(fd)
        require(re.fullmatch(rb"[0-9a-f]{32}\n?", data) is not None and
                data.rstrip(b"\n") != b"0" * 32, "machine-id", "value")
        return data.rstrip(b"\n").decode("ascii")

    def command(self, tool, args, input_bytes=None, pass_fds=()):
        require(tool in ("/usr/bin/blkid", "/usr/bin/openssl"), "command", "tool")
        exe = self.open_canonical(tool, stat.S_IFREG, "command")
        proc = None
        try:
            require(os.fstat(exe).st_mode & 0o111, "command", "executable")
            parent_pid = os.getpid()
            proc = subprocess.Popen([tool, *args], executable="/proc/self/fd/" + str(exe),
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, close_fds=True,
                                    pass_fds=(*pass_fds, exe),
                                    preexec_fn=lambda: arm_parent_death(parent_pid),
                                    env={"LC_ALL": "C", "PATH": "/usr/bin",
                                         "HOME": "/nonexistent", "OPENSSL_CONF": "/dev/null",
                                         "BLKID_CONF": "/dev/null"})
            output, diagnostics = bytearray(), bytearray()
            pending = memoryview(input_bytes or b"")
            deadline = min(self.deadline, time.monotonic() + COMMAND_SECONDS)
            with selectors.DefaultSelector() as selector:
                for stream, role in ((proc.stdout, "out"), (proc.stderr, "err")):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ, role)
                if pending:
                    os.set_blocking(proc.stdin.fileno(), False)
                    selector.register(proc.stdin, selectors.EVENT_WRITE, "in")
                else:
                    proc.stdin.close()
                while selector.get_map():
                    require(time.monotonic() < deadline, "command", "timeout")
                    for key, _ in selector.select(min(0.1, max(0, deadline - time.monotonic()))):
                        if key.data == "in":
                            written = os.write(key.fd, pending[:16384])
                            pending = pending[written:]
                            if not pending:
                                selector.unregister(key.fileobj)
                                key.fileobj.close()
                            continue
                        chunk = os.read(key.fd, 16384)
                        self.charge(len(chunk))
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        target = output if key.data == "out" else diagnostics
                        target.extend(chunk)
                        require(len(target) <= (MAX_COMMAND_BYTES if key.data == "out"
                                                else MAX_STDERR_BYTES), "command", "byte-limit")
            rc = proc.wait(timeout=max(0.001, deadline - time.monotonic()))
            require(not diagnostics, "command", "diagnostic")
            if tool == "/usr/bin/blkid":
                codes = {2: "unidentified", 4: "probe-error", 8: "collision"}
                require(rc == 0, "device-probe", codes.get(rc, "exit"))
            else:
                require(rc == 0, "certificate", "der")
            return bytes(output)
        finally:
            if proc is not None:
                if proc.poll() is None:
                    proc.kill()
                    # The outer worker supervisor is the hard wall-clock bound,
                    # including uninterruptible kernel I/O and extension calls.
                    try:
                        proc.wait(timeout=0.2)
                    except subprocess.TimeoutExpired:
                        pass
                for stream in (proc.stdin, proc.stdout, proc.stderr):
                    stream.close()
            os.close(exe)

    def certificate(self, fd):
        st = os.fstat(fd)
        controlled(st, stat.S_IFREG, "certificate")
        require(0 < st.st_size <= MAX_CERT_BYTES, "certificate", "limit")
        data = self.read_fd(fd, MAX_CERT_BYTES, "certificate", positional=True)
        require(len(data) == st.st_size and file_identity(st) == file_identity(os.fstat(fd)),
                "certificate", "drift")
        der = pem_der(data)
        checked = self.command("/usr/bin/openssl", ["x509", "-inform", "DER", "-outform", "DER"], der)
        require(checked == der, "certificate", "roundtrip")
        return hashlib.sha256(der).hexdigest()

    def btrfs_api(self):
        require(sys.flags.isolated and sys.flags.no_site and sys.flags.ignore_environment,
                "btrfs-api", "isolation")
        platlib = canonical_path(sysconfig.get_path("platlib"))
        suffix = sysconfig.get_config_var("EXT_SUFFIX")
        require(type(suffix) is str and suffix in importlib.machinery.EXTENSION_SUFFIXES,
                "btrfs-api", "abi")
        path = platlib + "/btrfsutil" + suffix
        fd = self.open_canonical(path, stat.S_IFREG, "btrfs-api")
        try:
            before = file_identity(os.fstat(fd))
            # Explicit extension-only spec: no sys.path edit, site import, .pth,
            # Python wrapper, directory package, user module or default importer.
            loader = importlib.machinery.ExtensionFileLoader("btrfsutil", path)
            spec = importlib.util.spec_from_file_location("btrfsutil", path, loader=loader)
            module = importlib.util.module_from_spec(spec)
            loader.exec_module(module)
            require(module.__file__ == path and
                    type(module.subvolume_id) is types.BuiltinFunctionType and
                    type(module.subvolume_info) is types.BuiltinFunctionType and
                    isinstance(module.SubvolumeInfo, type) and
                    module.SubvolumeInfo.__module__ == "btrfsutil",
                    "btrfs-api", "contract")
            fresh = self.open_canonical(path, stat.S_IFREG, "btrfs-api")
            try:
                require(before == file_identity(os.fstat(fd)) == file_identity(os.fstat(fresh)),
                        "btrfs-api", "drift")
            finally:
                os.close(fresh)
            return module
        finally:
            os.close(fd)

    def btrfs(self, fd):
        module = self.btrfs_api()
        result = btrfs_identity(module, fd, os.fstat(fd).st_ino)
        buffer = bytearray(1024)
        status = fcntl.ioctl(fd, 0x8400941F, buffer, True)
        require(type(status) is int and status == 0, "btrfs", "fs-info")
        fsid = uuid.UUID(bytes=bytes(buffer[16:32]))
        require(fsid.int != 0, "btrfs", "fsid")
        return result, str(fsid)

    def architecture(self):
        machine = os.uname().machine
        require(machine in ("x86_64", "aarch64"), "architecture", "unsupported")
        return machine

    def open_device(self, path, expected=None):
        canonical_path(path)
        require(beneath(path, "/dev"), "device", "source")
        resolved = self.resolve_owned(path, "device")
        require(beneath(resolved, "/dev"), "device", "source")
        fd = self.open_canonical(resolved, stat.S_IFBLK, "device")
        self.owned_fds.append(fd)
        st = os.fstat(fd)
        number = os.major(st.st_rdev), os.minor(st.st_rdev)
        require(expected is None or number == expected, "device", "devnum")
        return {"fd": fd, "path": path, "resolved": resolved,
                "identity": identity(st), "number": number}

    def recheck_device(self, device):
        require(self.resolve_owned(device["path"], "device") == device["resolved"],
                "device", "path-drift")
        fresh = self.open_canonical(device["resolved"], stat.S_IFBLK, "device")
        try:
            require(identity(os.fstat(fresh)) == device["identity"] ==
                    identity(os.fstat(device["fd"])), "device", "identity-drift")
        finally:
            os.close(fresh)

    def probe(self, device):
        self.recheck_device(device)
        path = "/proc/self/fd/" + str(device["fd"])
        args = ["--probe", "--output", "export"]
        for tag in TAGS:
            args.extend(("--match-tag", tag))
        args.extend(("--", path))
        result = parse_export(self.command("/usr/bin/blkid", args,
                                           pass_fds=(device["fd"],)), path)
        self.recheck_device(device)
        return result

    def inventory(self, mounts):
        return Inventory(self, mounts)


class Inventory:
    """Complete transient kernel partition coverage, never lsblk output.

    All sysfs rows are classified from checked dev/uevent/partition attributes.
    Every partition is directly probed, including unmounted/non-ESP partitions.
    Only partition relationships (plus selected sources) are equality-rechecked;
    unrelated whole disks need not remain identical after classification.
    """

    def __init__(self, system, mounts):
        self.system = system
        self.mounts = mounts
        self.fd = system.open_canonical("/sys/dev/block", stat.S_IFDIR, "coverage")
        system.owned_fds.append(self.fd)
        self.mid = system.mount_id(self.fd)
        require(self.mid in mounts and mounts[self.mid].kind == "sysfs" and
                mounts[self.mid].root == "/", "coverage", "sysfs")
        self.rows = self.scan()
        self.devices = {}

    def names(self):
        result = set()
        with os.scandir(self.fd) as entries:
            for entry in entries:
                self.system.charge(len(entry.name))
                devnum(entry.name)
                require(entry.name not in result and entry.is_symlink(),
                        "coverage", "entry")
                result.add(entry.name)
                require(len(result) <= MAX_DEVICES, "coverage", "row-limit")
        return result

    def attribute(self, fd, name, optional=False, raw=False):
        try:
            child = os.open(name, OPEN_READ, dir_fd=fd)
        except FileNotFoundError:
            if optional:
                return None
            raise
        try:
            controlled(os.fstat(child), stat.S_IFREG, "coverage")
            require(self.system.mount_id(child) == self.mid, "coverage", "attribute-mount")
            data = self.system.read_fd(child, 8192, "coverage")
            return data if raw else data.decode("ascii", "strict")
        finally:
            os.close(child)

    def row(self, name):
        link = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        require(stat.S_ISLNK(link.st_mode) and link.st_uid == 0, "coverage", "entry")
        target = self.system.resolve_owned("/sys/dev/block/" + name, "coverage")
        require(beneath(target, "/sys/devices"), "coverage", "sysfs-target")
        fd = self.system.open_canonical(target, stat.S_IFDIR, "coverage")
        try:
            before = identity(os.fstat(fd))
            require(self.system.mount_id(fd) == self.mid, "coverage", "row-mount")
            number = devnum(name)
            require(self.attribute(fd, "dev") == name + "\n", "coverage", "devnum")
            fields = parse_uevent(self.attribute(fd, "uevent", raw=True))
            require(fields.get("MAJOR") == str(number[0]) and
                    fields.get("MINOR") == str(number[1]), "coverage", "devnum")
            devname = fields.get("DEVNAME")
            require(type(devname) is str and devname == target.rsplit("/", 1)[1].replace("!", "/"),
                    "coverage", "name")
            canonical_path("/dev/" + devname)
            part = self.attribute(fd, "partition", optional=True)
            require(fields.get("DEVTYPE") == ("disk" if part is None else "partition"),
                    "coverage", "classification")
            if part is None and re.fullmatch(r"dm-[0-9]+", devname):
                dm_uuid = self.attribute(fd, "dm/uuid", raw=True)
                require(type(dm_uuid) is bytes and dm_uuid.endswith(b"\n"),
                        "coverage", "mapped-classification")
                # libblkid also recognizes kpartx's partN-* UUID on a DEVTYPE
                # disk. Do not silently omit that plausible duplicate from the
                # partition universe. Its slave/parent custody counterpart is
                # not implemented here; ordinary LUKS/LVM root maps remain valid.
                require(re.match(rb"(?i:part)[0-9]+-", dm_uuid) is None,
                        "coverage", "mapped-partition-incomplete")
            parent = None
            detail = None
            if part is not None:
                require(part.endswith("\n") and decimal(part[:-1], "coverage") > 0,
                        "coverage", "partition")
                require("PARTN" not in fields or fields["PARTN"] == part[:-1],
                        "coverage", "partition-number")
                parent_path = target.rsplit("/", 1)[0]
                pfd = self.system.open_canonical(parent_path, stat.S_IFDIR, "coverage")
                try:
                    require(self.system.mount_id(pfd) == self.mid, "coverage", "parent-mount")
                    pdev = self.attribute(pfd, "dev")
                    require(pdev.endswith("\n"), "coverage", "parent")
                    parent = devnum(pdev[:-1])
                finally:
                    os.close(pfd)
                numbers = []
                for attr in ("start", "size"):
                    value = self.attribute(fd, attr)
                    require(value.endswith("\n"), "coverage", "partition")
                    numbers.append(decimal(value[:-1], "coverage"))
                require(numbers[1] > 0, "coverage", "partition")
                detail = (int(part), *numbers)
            require(before == identity(os.fstat(fd)) and
                    identity(link) == identity(os.stat(name, dir_fd=self.fd, follow_symlinks=False)) and
                    self.system.resolve_owned("/sys/dev/block/" + name, "coverage") == target,
                    "coverage", "row-drift")
            return {"number": number, "path": "/dev/" + devname, "target": target,
                    "identity": before, "link": identity(link), "parent": parent,
                    "partition": detail}
        finally:
            os.close(fd)

    def scan(self):
        self.system.charge(0)
        before = self.names()
        result = {}
        for name in sorted(before):
            self.system.charge(0)
            row = self.row(name)
            require(row["number"] not in result, "coverage", "duplicate-devnum")
            result[row["number"]] = row
        require(before == self.names(), "coverage", "enumeration-drift")
        for row in result.values():
            if row["partition"] is not None:
                require(row["parent"] in result and
                        result[row["parent"]]["partition"] is None,
                        "coverage", "parent-missing")
        return result

    def bind(self, number):
        require(number in self.rows, "coverage", "source-missing")
        if number not in self.devices:
            self.devices[number] = self.system.open_device(self.rows[number]["path"], number)
        return self.devices[number]

    def check_row(self, number):
        name = str(number[0]) + ":" + str(number[1])
        require(self.row(name) == self.rows[number], "coverage", "relationship-drift")
        self.system.recheck_device(self.bind(number))

    def partitions(self):
        result = {}
        for number, row in self.rows.items():
            self.system.charge(0)
            if row["partition"] is None:
                continue
            self.bind(row["parent"])
            self.check_row(number)
            self.check_row(row["parent"])
            tags = self.system.probe(self.bind(number))
            self.system.charge(0)
            self.check_row(number)
            self.check_row(row["parent"])
            result[number] = partition_identity(tags)
        return result

    def census(self):
        """Recheck source coverage and held relationships without device probes."""
        fresh = self.scan()
        old_parts = {n: r for n, r in self.rows.items() if r["partition"] is not None}
        new_parts = {n: r for n, r in fresh.items() if r["partition"] is not None}
        require(old_parts == new_parts, "coverage", "partition-drift")
        for number, device in self.devices.items():
            require(number in fresh and fresh[number] == self.rows[number],
                    "coverage", "relationship-drift")
            self.system.recheck_device(device)
        self.system.charge(0)

    def finish(self, previous):
        self.census()
        require(self.partitions() == previous, "coverage", "identity-drift")
        self.census()


def root_context(system, args, mount, source):
    kind = mount.kind
    require(kind in ("ext2", "ext3", "ext4", "xfs", "btrfs"), "root", "filesystem")
    tags = system.probe(source)
    require(tags.get("TYPE") == kind, "root", "filesystem-mismatch")
    fsid = uuid_text(tags.get("UUID"), "root")
    subvolume = None
    if kind == "btrfs":
        subvolume, mounted_fsid = system.btrfs(args["root_fd"])
        require(fsid == mounted_fsid, "root", "mounted-fsid-incomplete")
    else:
        require(mount.root == "/", "root", "directory-bind-incomplete")
        require(source["number"] == mount.device, "root", "device-mismatch")
    return {"path": args["root_path"], "filesystem_type": kind,
            "filesystem_uuid": fsid, "subvolume": subvolume}


def collect(system, args):
    namespace = system.namespace()
    root_pin = system.bind_directory(args["root_fd"], args["root_path"])
    esp_pin = system.bind_directory(args["esp_fd"], args["esp_path"])
    mounts = system.mounts()
    root, esp = select_mounts(mounts, root_pin[1], esp_pin[1],
                              args["root_path"], args["esp_path"])
    # Btrfs getattr can expose a per-subvolume anonymous device, whereas
    # mountinfo reports the superblock device. FD mount IDs join those views;
    # FS_INFO plus the direct member probe joins the mounted filesystem.
    require((root.kind == "btrfs" or
             (os.major(root_pin[0][0]), os.minor(root_pin[0][0])) == root.device) and
            (os.major(esp_pin[0][0]), os.minor(esp_pin[0][0])) == esp.device,
            "mounts", "device-mismatch")
    system.configuration(args["config_path"], esp.id)
    source = system.open_device(root.source)
    esp_source = system.open_device(esp.source, esp.device)
    inventory = system.inventory(mounts)
    inventory.bind(source["number"])
    inventory.bind(esp_source["number"])
    partitions = inventory.partitions()
    body = {"schema_version": 1, "architecture": system.architecture(),
            "machine_id": system.machine_id(args["root_fd"]),
            "root": root_context(system, args, root, source),
            "esp": {"path": args["esp_path"],
                    **unique_esp(esp_source["number"], system.probe(esp_source), partitions)},
            "configuration_path": args["config_path"],
            "local_db_certificate_der_sha256": system.certificate(args["certificate_fd"])}
    inventory.finish(partitions)
    require(body["root"] == root_context(system, args, root, source) and
            body["esp"] == {"path": args["esp_path"],
                            **unique_esp(esp_source["number"], system.probe(esp_source), partitions)} and
            body["machine_id"] == system.machine_id(args["root_fd"]) and
            body["local_db_certificate_der_sha256"] == system.certificate(args["certificate_fd"]) and
            body["architecture"] == system.architecture(), "context", "stable-field-drift")
    system.recheck_device(source)
    system.recheck_device(esp_source)
    # Crypto and the final selected-device probes also allow hotplug time.
    # Close that interval with complete checked coverage on the same deadline;
    # a new/changed partition invalidates the earlier uniqueness observation.
    # Final mount/FD custody checks still bracket the whole observation below.
    inventory.census()
    system.configuration(args["config_path"], esp.id)
    require(select_mounts(system.mounts(), root.id, esp.id, args["root_path"],
                          args["esp_path"]) == (root, esp), "mounts", "drift")
    require(system.bind_directory(args["root_fd"], args["root_path"]) == root_pin and
            system.bind_directory(args["esp_fd"], args["esp_path"]) == esp_pin and
            system.namespace() == namespace, "custody", "drift")
    return {"format": FORMAT, "schema": 1, "complete": True, "context": body}


def failure(operation, code):
    return {"format": FORMAT, "schema": 1, "complete": False,
            "error": {"operation": operation, "code": code}}


def observe(argv):
    system = System()
    try:
        args = parse_args(argv)
        require(sys.flags.isolated and sys.flags.no_site and sys.flags.ignore_environment,
                "arguments", "isolation")
        if args is None:
            system.btrfs_api()
            return {"format": FORMAT + "-api", "schema": 1, "complete": True,
                    "api": "btrfsutil-fd-explicit-id-v1"}
        return collect(system, args)
    except Incomplete as error:
        return failure(error.operation, error.code)
    except Exception:
        # Includes OS/codec/import/API exceptions. Their messages can contain
        # acquired bytes, paths or external diagnostics and must stay private.
        return failure("observation", "unavailable")
    finally:
        system.close()


def encode_result(result):
    return json.dumps(result, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode("ascii") + b"\n"


def decode_result(data, args):
    """One exact typed frame, including strict mode and body shape checks."""
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, "supervisor", "framing")
            result[key] = value
        return result

    require(type(data) is bytes and 0 < len(data) <= MAX_RESULT_BYTES and
            data.startswith(b"{") and data.endswith(b"}\n") and data.count(b"\n") == 1,
            "supervisor", "framing")
    result = json.loads(data.decode("ascii"), object_pairs_hook=unique_pairs,
                        parse_constant=lambda _value: require(False, "supervisor", "framing"))
    require(type(result) is dict and type(result.get("schema")) is int and result["schema"] == 1 and
            type(result.get("complete")) is bool, "supervisor", "framing")
    if not result["complete"]:
        require(set(result) == {"format", "schema", "complete", "error"} and result["format"] == FORMAT and
                type(result["error"]) is dict and set(result["error"]) == {"operation", "code"} and
                all(type(v) is str and re.fullmatch(r"[a-z][a-z0-9-]{0,63}", v) is not None
                    for v in result["error"].values()), "supervisor", "framing")
        return result
    if args is None:
        require(set(result) == {"format", "schema", "complete", "api"} and
                result["format"] == FORMAT + "-api" and result["api"] == "btrfsutil-fd-explicit-id-v1",
                "supervisor", "framing")
        return result
    require(set(result) == {"format", "schema", "complete", "context"} and result["format"] == FORMAT,
            "supervisor", "framing")
    body = result["context"]
    require(type(body) is dict and set(body) == {"schema_version", "architecture", "machine_id", "root", "esp",
                                                "configuration_path", "local_db_certificate_der_sha256"} and
            type(body["schema_version"]) is int and body["schema_version"] == 1 and
            body["architecture"] in ("x86_64", "aarch64") and
            type(body["machine_id"]) is str and re.fullmatch(r"[0-9a-f]{32}", body["machine_id"]) is not None and
            body["machine_id"] != "0" * 32 and body["configuration_path"] == args["config_path"] and
            type(body["local_db_certificate_der_sha256"]) is str and
            re.fullmatch(r"[0-9a-f]{64}", body["local_db_certificate_der_sha256"]) is not None,
            "supervisor", "framing")
    root, esp = body["root"], body["esp"]
    require(type(root) is dict and set(root) == {"path", "filesystem_type", "filesystem_uuid", "subvolume"} and
            root["path"] == args["root_path"] and root["filesystem_type"] in ("ext2", "ext3", "ext4", "xfs", "btrfs") and
            uuid_text(root["filesystem_uuid"], "supervisor") == root["filesystem_uuid"], "supervisor", "framing")
    subvolume = root["subvolume"]
    if root["filesystem_type"] == "btrfs":
        require(type(subvolume) is dict and set(subvolume) == {"kind", "id", "uuid"}, "supervisor", "framing")
        ident = decimal(subvolume["id"], "supervisor", LAST_FREE)
        require((subvolume["kind"] == "top-level" and ident == 5) or
                (subvolume["kind"] == "subvolume" and ident >= 256), "supervisor", "framing")
        require((ident == 5 and subvolume["uuid"] is None) or
                uuid_text(subvolume["uuid"], "supervisor") == subvolume["uuid"], "supervisor", "framing")
    else:
        require(subvolume is None, "supervisor", "framing")
    require(type(esp) is dict and set(esp) == {"path", "partition_scheme", "partition_uuid", "partition_type",
                                             "filesystem_type", "filesystem_uuid"} and
            esp["path"] == args["esp_path"] and esp["partition_scheme"] == "gpt" and
            esp["partition_type"] == ESP_GUID and esp["filesystem_type"] == "vfat" and
            uuid_text(esp["partition_uuid"], "supervisor") == esp["partition_uuid"] and
            type(esp["filesystem_uuid"]) is str and re.fullmatch(r"[0-9A-F]{4}-[0-9A-F]{4}", esp["filesystem_uuid"]) is not None,
            "supervisor", "framing")
    return result


class OwnedChild:
    """A fork result remains signaling authority only until its one actual reap.

    WNOWAIT keeps a terminal child and its PID reserved while its process group
    is quenched. No numeric PID or group is signaled after reaping or loss of
    wait ownership; no historical PID/pgid or host process inventory is used.
    """

    def __init__(self, pid, group=False):
        self.pid, self.group, self.owned = pid, group, True

    def peek(self):
        require(self.owned, "supervisor", "child-ownership")
        try:
            return os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError:
            self.owned = False
            raise Incomplete("supervisor", "child-ownership") from None

    def kill(self):
        info = self.peek()
        try:
            if self.group and os.getpgid(self.pid) == self.pid:
                os.killpg(self.pid, signal.SIGKILL)
            elif info is None:
                os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            # A reserved, terminal child needs only collection. Never substitute
            # an unrelated/current pathname, PID or process group on uncertainty.
            require(self.peek() is not None, "supervisor", "child-identity")

    def reap(self):
        require(self.owned, "supervisor", "child-ownership")
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.owned = False
            raise Incomplete("supervisor", "child-ownership") from None
        if pid == 0:
            return None
        self.owned = False
        require(pid == self.pid, "supervisor", "child-ownership")
        return status

    def cleanup(self, drain=0):
        if not self.owned:
            return
        # The outer parent first closes its lifeline, allowing the independent
        # guardian to quench descendants even if the worker is stuck in C/I/O.
        deadline = time.monotonic() + drain
        while drain and time.monotonic() < deadline:
            if self.peek() is not None:
                self.reap()
                return
            time.sleep(0.01)
        self.kill()
        deadline = time.monotonic() + CLEANUP_SECONDS
        while True:
            if self.reap() is not None or time.monotonic() >= deadline:
                return
            time.sleep(0.01)


def receive_worker(child, read_fd, deadline, args, lifeline=None):
    data = bytearray()
    eof = False
    os.set_blocking(read_fd, False)
    with selectors.DefaultSelector() as selector:
        selector.register(read_fd, selectors.EVENT_READ, "result")
        if lifeline is not None:
            selector.register(lifeline, selectors.EVENT_READ, "parent")
        while True:
            require(time.monotonic() < deadline, "supervisor", "timeout")
            info = child.peek()
            if eof and info is not None:
                # The terminal worker remains unreaped while group cleanup
                # runs, so a successful JSON frame cannot outlive a failed or
                # still-running worker, nor authorize signaling a reused PID.
                if child.group:
                    child.kill()
                status = child.reap()
                require(status is not None and time.monotonic() < deadline, "supervisor", "timeout")
                try:
                    result = decode_result(bytes(data), args)
                except Exception:
                    raise Incomplete("supervisor", "framing") from None
                require(not result["complete"] or (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0),
                        "supervisor", "worker-exit")
                return result
            for key, _ in selector.select(min(0.02, max(0, deadline - time.monotonic()))):
                require(key.data != "parent", "supervisor", "parent-terminated")
                chunk = os.read(key.fd, 16384)
                if not chunk:
                    eof = True
                    selector.unregister(read_fd)
                    continue
                data.extend(chunk)
                require(len(data) <= MAX_RESULT_BYTES, "supervisor", "byte-limit")


def write_result(fd, result):
    pending = memoryview(encode_result(result))
    require(len(pending) <= MAX_RESULT_BYTES, "supervisor", "byte-limit")
    while pending:
        pending = pending[os.write(fd, pending):]


def guardian(argv, args, deadline, lifeline):
    """Separate-session watchdog; parent death is observable as pipe EOF.

    Only the outer parent retains the lifeline writer. This watchdog executes
    no filesystem/device observation and survives an external kill of the
    outer parent, then kills its own unreaped worker group before collecting
    actual status. The worker and fixed commands also arm PDEATHSIG as a
    backstop for unexpected death of an intermediate supervisor.
    """
    child = None
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
    try:
        parent_pid = os.getpid()
        pid = os.fork()
        if pid == 0:
            try:
                os.setpgid(0, 0)
                arm_parent_death(parent_pid)
                reset_child_signals()
                os.dup2(write_fd, 1)
                os.dup2(write_fd, 2)
                close_inherited_fds(supplied_fds(args))
                result = observe(argv)
                write_result(1, result)
                os._exit(0 if result["complete"] else 1)
            except BaseException:
                os._exit(125)
        child = OwnedChild(pid, group=True)
        os.setpgid(pid, pid)
        os.close(write_fd)
        write_fd = None
        return receive_worker(child, read_fd, deadline, args, lifeline)
    except Incomplete as error:
        return failure(error.operation, error.code)
    except Exception:
        return failure("supervisor", "unavailable")
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)
        if child is not None:
            child.cleanup()


class ParentTerminated(BaseException):
    pass


def supervised(argv):
    """One shared 60s deadline for observation, complete frame and actual exit.

    Signal cleanup has a 0.5s guardian-drain plus at most 0.25s forced-reap
    budget; it never accepts success after the observation deadline. SIGKILL
    of this parent instead closes the private lifeline, waking the guardian.
    """
    args = parse_args(argv)
    deadline = time.monotonic() + TOTAL_SECONDS
    child = None
    pipe_fds = []
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATION_SIGNALS)
    handlers = {signum: signal.getsignal(signum) for signum in (*TERMINATION_SIGNALS, signal.SIGCHLD)}

    def terminated(_signum, _frame):
        raise ParentTerminated()

    try:
        signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        for signum in TERMINATION_SIGNALS:
            signal.signal(signum, terminated)
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        pipe_fds.extend((read_fd, write_fd))
        life_read, life_write = os.pipe2(os.O_CLOEXEC)
        pipe_fds.extend((life_read, life_write))
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                reset_child_signals()
                os.dup2(write_fd, 1)
                os.dup2(write_fd, 2)
                close_inherited_fds(supplied_fds(args) | {life_read})
                result = guardian(argv, args, deadline, life_read)
                write_result(1, result)
                os._exit(0 if result["complete"] else 1)
            except BaseException:
                os._exit(125)
        child = OwnedChild(pid)
        for fd in (write_fd, life_read):
            os.close(fd)
            pipe_fds.remove(fd)
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        return receive_worker(child, read_fd, deadline, args)
    except ParentTerminated:
        return failure("supervisor", "parent-terminated")
    except Incomplete as error:
        return failure(error.operation, error.code)
    except Exception:
        return failure("supervisor", "unavailable")
    finally:
        signal.pthread_sigmask(signal.SIG_BLOCK, TERMINATION_SIGNALS)
        try:
            for fd in pipe_fds:
                os.close(fd)
            if child is not None:
                child.cleanup(drain=GUARD_DRAIN_SECONDS)
        finally:
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def main(argv):
    try:
        # Reject malformed arguments before forking or querying any observation.
        args = parse_args(argv)
        close_inherited_fds(supplied_fds(args))
        result = supervised(argv)
    except Incomplete as error:
        result = failure(error.operation, error.code)
    except Exception:
        result = failure("supervisor", "unavailable")
    sys.stdout.write(json.dumps(result, separators=(",", ":"), ensure_ascii=True) + "\n")
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
