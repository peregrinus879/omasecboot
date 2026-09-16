#!/usr/bin/python
"""Fixture-only contract for publication-context.py.

Usage: python -I -S PublicationContextContract.py INSPECTOR_PATH SCRATCH_PARENT
The runner supplies a private scratch parent. No collector runs against the host:
hardware acquisition is replaced in this test module, never via production flags
or environment variables. OpenSSL sees only generated disposable public fixtures;
its ephemeral signing key is generated/consumed by OpenSSL and never read here.
"""

import base64
import collections
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest import mock
import uuid


if len(sys.argv) not in (3, 5):
    raise SystemExit("usage: PublicationContextContract.py INSPECTOR_PATH SCRATCH_PARENT")
INSPECTOR = Path(sys.argv[1]).absolute()
SCRATCH = Path(sys.argv[2]).absolute()
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("publication_context_contract_target", INSPECTOR)
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)

FS_UUID = "11111111-2222-3333-4444-555555555555"
PART_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
OTHER_UUID = "cccccccc-bbbb-aaaa-dddd-eeeeeeeeeeee"
SUB_UUID = "01234567-89ab-cdef-0123-456789abcdef"
MACHINE_ID = "a123456789abcdef0123456789abcdef"
ARGV = ["--root-fd", "40", "--esp-fd", "41", "--root-path", "/",
        "--esp-path", "/boot", "--config-path", "/boot/limine.conf",
        "--certificate-fd", "42"]
ARGS = pc.parse_args(ARGV)


def export(tags, fd=80):
    return ("DEVNAME=/proc/self/fd/" + str(fd) + "\n" +
            "".join(k + "=" + v + "\n" for k, v in tags.items())).encode("ascii")


def esp_tags(**updates):
    result = {"TYPE": "vfat", "UUID": "abcd-1234", "PART_ENTRY_SCHEME": "gpt",
              "PART_ENTRY_UUID": PART_UUID, "PART_ENTRY_TYPE": pc.ESP_GUID}
    result.update(updates)
    return result


def mountinfo(root_kind="ext4", root_dev="253:0", root="/", root_path="/"):
    return (f"10 1 {root_dev} {root} {root_path} rw,relatime shared:1 - {root_kind} /dev/dm-0 rw\n"
            f"20 10 8:1 / /boot rw,relatime - vfat /dev/sda1 rw\n"
            f"30 10 0:5 / /sys rw,nosuid - sysfs sysfs rw\n").encode("ascii")


def synthetic_stat(kind=stat.S_IFREG, mode=0o644, ino=19, device=1, rdev=0,
                   size=0, uid=0):
    return types.SimpleNamespace(st_dev=device, st_ino=ino, st_mode=kind | mode,
                                 st_uid=uid, st_gid=0, st_rdev=rdev, st_size=size,
                                 st_mtime_ns=100, st_ctime_ns=100)


class FixtureInventory:
    def __init__(self, hardware):
        self.hardware = hardware
        self.numbers = set(hardware.partition_rows)

    def bind(self, number):
        pc.require(number in ((253, 0), (8, 1)), "coverage", "source-missing")

    def partitions(self):
        return dict(self.hardware.partition_rows)

    def finish(self, previous):
        pc.require(previous == self.hardware.partition_rows, "coverage", "drift")

    def census(self):
        self.hardware.event("census")
        pc.require(set(self.hardware.partition_rows) == self.numbers, "coverage", "partition-drift")


class FixtureHardware:
    """Only synthetic data, with conspicuous failure on unimplemented seams."""

    def __init__(self, kind="ext4"):
        self.kind = kind
        self.root_device = (0, 99) if kind == "btrfs" else (253, 0)
        mount_device = (0, 98) if kind == "btrfs" else self.root_device
        self.mount_bytes = mountinfo(kind, ":".join(map(str, mount_device)),
                                    "/@" if kind == "btrfs" else "/")
        self.partition_rows = {(8, 1): pc.partition_identity(esp_tags())}
        self.subvolume = {"kind": "subvolume", "id": "256", "uuid": SUB_UUID}
        self.mounted_uuid = FS_UUID
        self.machine = MACHINE_ID
        self.fingerprint = "a" * 64
        self.root_tags = {"TYPE": kind, "UUID": FS_UUID}
        self.esp_tags = esp_tags()
        self.events = []
        self.counts = collections.Counter()
        self.after = {}

    def event(self, name):
        self.events.append(name)
        self.counts[name] += 1
        action = self.after.get((name, self.counts[name]))
        if action:
            action()

    def namespace(self):
        self.event("namespace")
        return 7, 101

    def bind_directory(self, fd, path):
        self.event("bind-" + str(fd))
        if fd == 40:
            return (os.makedev(*self.root_device), 256, stat.S_IFDIR | 0o755, 0, 0, 0), 10
        assert fd == 41 and path == "/boot"
        return (os.makedev(8, 1), 2, stat.S_IFDIR | 0o755, 0, 0, 0), 20

    def mounts(self):
        self.event("mounts")
        return pc.parse_mountinfo(self.mount_bytes)

    def configuration(self, path, esp_id):
        self.event("configuration")
        assert path == "/boot/limine.conf" and esp_id == 20

    def open_device(self, path, expected=None):
        self.event("open-device")
        number = {"/dev/dm-0": (253, 0), "/dev/sda1": (8, 1)}[path]
        assert expected in (None, number)
        return {"number": number, "path": path, "fd": 80 if number == (253, 0) else 81}

    def inventory(self, mounts):
        self.event("inventory")
        return FixtureInventory(self)

    def probe(self, device):
        self.event("probe-" + str(device["fd"]))
        return dict(self.root_tags if device["number"] == (253, 0) else self.esp_tags)

    def recheck_device(self, device):
        self.event("recheck-" + str(device["fd"]))

    def architecture(self):
        self.event("architecture")
        return "x86_64"

    def machine_id(self, fd):
        assert fd == 40
        self.event("machine-id")
        return self.machine

    def certificate(self, fd):
        assert fd == 42
        self.event("certificate")
        return self.fingerprint

    def btrfs(self, fd):
        assert fd == 40
        self.event("btrfs")
        return dict(self.subvolume), self.mounted_uuid

    def close(self):
        pass


class Contract(unittest.TestCase):
    def refused(self, callable_, *args, code=None):
        with self.assertRaises(pc.Incomplete) as raised:
            callable_(*args)
        if code is not None:
            self.assertEqual(raised.exception.code, code)

    def test_argument_frame(self):
        self.assertEqual(pc.parse_args(ARGV)["root_fd"], 40)
        self.assertIsNone(pc.parse_args(["--probe-api"]))
        bad = [[], ARGV + ["--probe-api"], ARGV[:-1], ["--help"],
               ["--probe-api", "unused"], ["--root-fd=40", *ARGV[2:]],
               ["--unknown", *ARGV[1:]], [*ARGV[:2], *ARGV[:2], *ARGV[4:]]]
        for frame in bad:
            with self.subTest(frame=frame):
                self.refused(pc.parse_args, frame)
        for value in ("0", "2", "-1", "040", "+40", "40 ", "true", "1048576"):
            self.refused(pc.parse_args, [ARGV[0], value, *ARGV[2:]])
        self.refused(pc.parse_args, [*ARGV[:3], "40", *ARGV[4:]])

    def test_canonical_paths_and_esp_containment(self):
        for value in ("", "relative", "//boot", "/boot/", "/boot//file", "/boot/../x",
                      "/boot/./x", "/boot/a\n", "/boot/a\t", "/boot/a\x7f", "/a\x85",
                      "/" + "a" * 4096, "/a/" * 129):
            self.refused(pc.canonical_path, value)
        self.assertEqual(pc.canonical_path("/boot/a b"), "/boot/a b")
        for value in ("/boot", "/boot-other/config", "/limine.conf"):
            frame = list(ARGV)
            frame[9] = value
            self.refused(pc.parse_args, frame)

    def test_controlled_kinds_and_stock_block_mode(self):
        pc.controlled(synthetic_stat(stat.S_IFBLK, 0o660), stat.S_IFBLK, "device")
        for kind in (stat.S_IFREG, stat.S_IFLNK, stat.S_IFIFO, stat.S_IFCHR):
            self.refused(pc.controlled, synthetic_stat(kind), stat.S_IFDIR, "custody")
        for item in (synthetic_stat(mode=0o666), synthetic_stat(uid=1000)):
            self.refused(pc.controlled, item, stat.S_IFREG, "certificate")

    def test_mount_parser_and_selection(self):
        mounts = pc.parse_mountinfo(mountinfo())
        root, esp = pc.select_mounts(mounts, 10, 20, "/", "/boot")
        self.assertEqual(root.source, "/dev/dm-0")
        self.assertEqual(esp.device, (8, 1))
        for data in (b"", mountinfo()[:-1], mountinfo().replace(b"\n", b"\r\n"),
                     mountinfo() + mountinfo(), mountinfo().replace(b"rw,relatime", b"rw  bad", 1),
                     mountinfo().replace(b"/boot", b"/bo\\001ot"),
                     mountinfo().replace(b"253:0", b"253:00"),
                     mountinfo().replace(b"10 1", b"0 1"),
                     mountinfo().replace(b"shared:1", b"bad:hello")):
            self.refused(pc.parse_mountinfo, data)
        for suffix in (b"21 20 8:2 / /boot/nested rw - ext4 /dev/sda2 rw\n",
                       b"21 20 8:2 / /elsewhere rw - ext4 /dev/sda2 rw\n"):
            self.refused(pc.select_mounts, pc.parse_mountinfo(mountinfo() + suffix),
                         10, 20, "/", "/boot")
        bad = pc.parse_mountinfo(mountinfo().replace(b"8:1 / /boot", b"8:1 /dir /boot"))
        self.refused(pc.select_mounts, bad, 10, 20, "/", "/boot")
        self.refused(pc.select_mounts, mounts, 10, 99, "/", "/boot")

    def test_visible_mount_stack_ignores_covered_lower_children(self):
        data = mountinfo().replace(b"20 10", b"20 19") + (
            b"19 10 8:2 / /boot rw - vfat /dev/sda2 rw\n"
            b"18 19 8:3 / /boot/hidden-old-child rw - ext4 /dev/sda3 rw\n")
        selected = pc.select_mounts(pc.parse_mountinfo(data), 10, 20, "/", "/boot")
        self.assertEqual(selected[1].id, 20)
        # A selected mount's own child still blocks, including deeper stacks.
        for extra in (b"21 20 8:4 / /boot/current rw - ext4 /dev/sda4 rw\n",
                      b"21 20 8:4 / /boot rw - vfat /dev/sda4 rw\n"):
            self.refused(pc.select_mounts, pc.parse_mountinfo(data + extra), 10, 20, "/", "/boot", code="esp-child")
        # A covered root and its old ESP subtree are outside the visible root.
        data = mountinfo().replace(b"10 1 ", b"10 9 ") + (
            b"9 1 8:5 / / rw - ext4 /dev/sda5 rw\n"
            b"19 9 8:2 / /boot rw - vfat /dev/sda2 rw\n"
            b"18 19 8:3 / /boot/hidden-old-child rw - ext4 /dev/sda3 rw\n")
        self.assertEqual(pc.select_mounts(pc.parse_mountinfo(data), 10, 20, "/", "/boot")[0].id, 10)

    def test_unselected_mount_path_bytes_are_opaque(self):
        hardware = FixtureHardware()
        hardware.mount_bytes += b"77 10 8:7 /foreign-\xff /unrelated-\xfe rw - ext4 /dev/foreign-\xff rw\n"
        result = pc.collect(hardware, ARGS)
        self.assertTrue(result["complete"])
        self.assertNotIn("foreign", json.dumps(result))
        self.assertIn("\udcfe", pc.parse_mountinfo(hardware.mount_bytes)[77].path)
        # Such bytes in the selected authority path remain invalid.
        bad = pc.parse_mountinfo(mountinfo().replace(b"/dev/sda1", b"/dev/sda\xff"))
        self.refused(pc.select_mounts, bad, 10, 20, "/", "/boot")

    def test_mount_control_bytes_are_scoped_to_selected_authority(self):
        for byte in (b"\x01", b"\x07", b"\x0b", b"\x0c", b"\r", b"\x1f", b"\x7f"):
            with self.subTest(byte=byte):
                hardware = FixtureHardware()
                hardware.mount_bytes += (b"77 10 8:7 /opaque-" + byte + b" /unselected-" + byte +
                                         b" rw - ext4 /dev/opaque-" + byte + b" rw,unused=" + byte + b"\n")
                self.assertTrue(pc.collect(hardware, ARGS)["complete"])
                for old, new in ((b"/dev/sda1", b"/dev/sda" + byte),
                                 (b"253:0 / /", b"253:0 /unsafe" + byte + b" /")):
                    mounts = pc.parse_mountinfo(mountinfo().replace(old, new))
                    self.refused(pc.select_mounts, mounts, 10, 20, "/", "/boot")
        for data in (mountinfo().replace(b"rw,relatime", b"rw\x01", 1),
                     mountinfo().replace(b"shared:1", b"shared:\x7f"),
                     mountinfo().replace(b" - ext4 ", b" - ex\x01t4 ")):
            self.refused(pc.parse_mountinfo, data)

    def test_fdinfo_complete_frame_and_fd_identity(self):
        data = b"pos:\t0\nflags:\t0104000\nmnt_id:\t10\nino:\t256\n"
        self.assertEqual(pc.parse_fdinfo(data), (10, 256))
        for bad in (data[:-1], data.replace(b"ino:\t256\n", b""), data + b"mnt_id:\t11\n",
                    data.replace(b"mnt_id:\t10", b"mnt_id: 10"),
                    data.replace(b"mnt_id:\t10", b"mnt_id:\t010"),
                    data.replace(b"flags:\t0104000", b"flags:\t089"),
                    data.replace(b"\n", b"\r\n")):
            self.refused(pc.parse_fdinfo, bad)
        system = pc.System()
        with mock.patch.object(system, "read_path", return_value=data), \
                mock.patch.object(pc.os, "fstat", side_effect=[synthetic_stat(ino=256), synthetic_stat(ino=257)]):
            self.refused(system.mount_id, 40, code="fdinfo-drift")
        with mock.patch.object(system, "read_path", return_value=data), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(ino=257)):
            self.assertEqual(system.mount_id(40), 10)

    def test_export_strict_framing(self):
        valid = export(esp_tags())
        self.assertEqual(pc.parse_export(valid, "/proc/self/fd/80"), esp_tags())
        for data in (valid[:-1], valid + b"\n", valid + b"UUID=ABCD-1111\n",
                     valid.replace(b"UUID=abcd-1234", b"UUID='abcd-1234'"),
                     valid.replace(b"UUID=abcd-1234", b"UUID=abcd-1234\r"),
                     valid.replace(b"TYPE=vfat", b"TYPE=vfat\x00"),
                     valid.replace(b"TYPE=vfat", b"TYPE=vfat\nEVIL=x"),
                     valid.replace(b"TYPE=vfat", b"TYPE="),
                     valid.replace(b"fd/80", b"fd/81"),
                     b"DEVNAME=/proc/self/fd/80\n", valid + valid):
            self.refused(pc.parse_export, data, "/proc/self/fd/80")

    def test_gpt_uniqueness_includes_unmounted_other_type(self):
        selected = pc.partition_identity(esp_tags())
        parts = {(8, 1): selected}
        expected = pc.unique_esp((8, 1), esp_tags(), parts)
        self.assertEqual(expected["filesystem_uuid"], "ABCD-1234")
        parts[(8, 2)] = ("gpt", OTHER_UUID, pc.ESP_GUID)
        self.assertEqual(pc.unique_esp((8, 1), esp_tags(), parts), expected)
        parts[(8, 3)] = ("gpt", PART_UUID, OTHER_UUID)
        self.refused(pc.unique_esp, (8, 1), esp_tags(), parts, code="duplicate-partuuid")
        self.refused(pc.unique_esp, (8, 1), esp_tags(), {}, code="selected-missing")

    def test_partition_scheme_requires_direct_known_evidence(self):
        for updates in ({"PART_ENTRY_SCHEME": "unknown"}, {"PART_ENTRY_SCHEME": "pmbr"},
                        {"PART_ENTRY_UUID": ""}, {"PART_ENTRY_UUID": "null"},
                        {"PART_ENTRY_UUID": "00000000-0000-0000-0000-000000000000"},
                        {"PART_ENTRY_TYPE": "not-a-guid"}):
            self.refused(pc.partition_identity, esp_tags(**updates))
        self.refused(pc.partition_identity, {"TYPE": "ext4", "UUID": FS_UUID})
        self.assertEqual(pc.partition_identity({"PART_ENTRY_SCHEME": "dos",
                                               "PART_ENTRY_TYPE": "0x83"}),
                         ("dos", None, "0x83"))
        self.refused(pc.partition_identity, {"PART_ENTRY_SCHEME": "dos"})

    def test_complete_body_and_no_live_identity_fields(self):
        hardware = FixtureHardware()
        result = pc.collect(hardware, ARGS)
        self.assertEqual(set(result), {"format", "schema", "complete", "context"})
        self.assertEqual(result["format"], pc.FORMAT)
        body = result["context"]
        self.assertEqual(set(body), {"schema_version", "architecture", "machine_id", "root", "esp",
                                     "configuration_path", "local_db_certificate_der_sha256"})
        self.assertEqual(body["root"], {"path": "/", "filesystem_type": "ext4",
                                        "filesystem_uuid": FS_UUID, "subvolume": None})
        self.assertEqual(body["machine_id"], MACHINE_ID)
        self.assertEqual(hardware.counts["machine-id"], 2)
        self.assertEqual(hardware.counts["certificate"], 2)
        self.assertEqual(hardware.counts["mounts"], 2)
        self.assertEqual(hardware.counts["bind-40"], 2)
        self.assertNotIn("/dev/", json.dumps(result))

    def test_mapped_root_and_supported_whole_filesystems(self):
        for kind in ("ext2", "ext3", "ext4", "xfs"):
            result = pc.collect(FixtureHardware(kind), ARGS)
            self.assertTrue(result["complete"])
            self.assertIsNone(result["context"]["root"]["subvolume"])
        hardware = FixtureHardware()
        hardware.mount_bytes = mountinfo(root="/directory")
        self.refused(pc.collect, hardware, ARGS, code="directory-bind-incomplete")

    def test_btrfs_anonymous_device_join_and_replacement(self):
        hardware = FixtureHardware("btrfs")
        before = pc.collect(hardware, ARGS)["context"]
        hardware.subvolume["uuid"] = OTHER_UUID
        after = pc.collect(hardware, ARGS)["context"]
        self.assertEqual(before["machine_id"], after["machine_id"])
        self.assertEqual(before["root"]["subvolume"]["id"], after["root"]["subvolume"]["id"])
        self.assertNotEqual(before["root"], after["root"])
        hardware.after[("btrfs", hardware.counts["btrfs"] + 2)] = lambda: hardware.subvolume.update(uuid=SUB_UUID)
        self.refused(pc.collect, hardware, ARGS, code="stable-field-drift")

    def test_root_mount_and_filesystem_uuid_mismatch(self):
        hardware = FixtureHardware("btrfs")
        hardware.mounted_uuid = OTHER_UUID
        self.refused(pc.collect, hardware, ARGS, code="mounted-fsid-incomplete")
        hardware = FixtureHardware()
        hardware.root_tags["TYPE"] = "crypto_LUKS"
        self.refused(pc.collect, hardware, ARGS, code="filesystem-mismatch")
        hardware = FixtureHardware()
        hardware.mount_bytes = mountinfo(root_dev="253:1")
        self.refused(pc.collect, hardware, ARGS, code="device-mismatch")

    def test_stable_reobservation_detects_changes(self):
        for name, change in (("machine-id", lambda h: setattr(h, "machine", "b" * 32)),
                             ("certificate", lambda h: setattr(h, "fingerprint", "b" * 64)),
                             ("mounts", lambda h: setattr(h, "mount_bytes", mountinfo(root="/other")))):
            hardware = FixtureHardware()
            hardware.after[(name, 2)] = lambda h=hardware, fn=change: fn(h)
            self.refused(pc.collect, hardware, ARGS)

    def test_collect_final_census_catches_second_certificate_interval_changes(self):
        # Actual collect/Inventory scan, probe, finish and census orchestration;
        # only kernel rows, block opens/probes and the context hardware are
        # synthetic. The certificate value stays identical across observations.
        for change in (None, "duplicate", "parent-replaced", "expired", "unreadable"):
            with self.subTest(change=change):
                clock = [100.0]
                broken = [False]
                hardware = FixtureHardware()
                rows = {
                    (253, 0): {"number": (253, 0), "path": "/dev/dm-0", "parent": None, "partition": None, "identity": 10},
                    (8, 0): {"number": (8, 0), "path": "/dev/sda", "parent": None, "partition": None, "identity": 11},
                    (8, 1): {"number": (8, 1), "path": "/dev/sda1", "parent": (8, 0), "partition": (1, 2048, 1024), "identity": 12},
                }
                tags = {(8, 1): esp_tags()}

                def names():
                    hardware.event("census-source")
                    if broken[0]:
                        raise OSError("fixture source enumeration failed")
                    return {str(a) + ":" + str(b) for a, b in rows}

                with mock.patch.object(pc.time, "monotonic", side_effect=lambda: clock[0]):
                    inventory = pc.Inventory.__new__(pc.Inventory)
                    inventory.system = pc.System()
                    inventory.devices = {}
                    deadline = inventory.system.deadline

                    def second_certificate():
                        if change == "duplicate":
                            rows[(8, 2)] = {"number": (8, 2), "path": "/dev/sda2", "parent": (8, 0),
                                            "partition": (2, 4096, 1024), "identity": 13}
                            tags[(8, 2)] = esp_tags()  # Same PARTUUID, deliberately unmounted.
                        elif change == "parent-replaced":
                            rows[(8, 0)]["identity"] = 99
                        elif change == "expired":
                            clock[0] = deadline + 0.01
                        elif change == "unreadable":
                            broken[0] = True

                    hardware.after[("certificate", 2)] = second_certificate
                    with mock.patch.object(inventory, "names", side_effect=names), \
                            mock.patch.object(inventory, "row", side_effect=lambda name: copy.deepcopy(rows[pc.devnum(name)])), \
                            mock.patch.object(inventory.system, "open_device", side_effect=lambda path, number: {"number": number, "path": path}), \
                            mock.patch.object(inventory.system, "recheck_device"), \
                            mock.patch.object(inventory.system, "probe", side_effect=lambda device: dict(tags[device["number"]])) as probe, \
                            mock.patch.object(hardware, "inventory", return_value=inventory):
                        inventory.rows = inventory.scan()
                        with mock.patch.object(pc, "System", return_value=hardware):
                            result = pc.observe(ARGV)
                        self.assertEqual(probe.call_count, 2, "final census must not repeat full partition probes")
                        self.assertEqual(hardware.counts["certificate"], 2)
                        self.assertEqual(inventory.system.deadline, deadline)
                        self.assertEqual(hardware.events[-1],
                                         "namespace" if change is None else
                                         "recheck-81" if change == "expired" else "census-source")
                        if change != "expired":
                            self.assertGreater(len(hardware.events) - 1 - hardware.events[::-1].index("census-source"),
                                               len(hardware.events) - 1 - hardware.events[::-1].index("certificate"))
                        if change is None:
                            self.assertTrue(result["complete"])
                        else:
                            self.assertFalse(result["complete"])
                            self.assertEqual(result["error"]["code"], {
                                "duplicate": "partition-drift", "parent-replaced": "relationship-drift",
                                "expired": "timeout", "unreadable": "unavailable"}[change])

    def test_btrfs_fd_explicit_id_and_metadata_types(self):
        Info = collections.namedtuple("SubvolumeInfo", "id parent_id uuid")
        calls = []
        module = types.SimpleNamespace(SubvolumeInfo=Info)
        module.subvolume_id = lambda fd: calls.append(("id", fd)) or 256
        module.subvolume_info = lambda fd, ident: calls.append(("info", fd, ident)) or Info(ident, 5, uuid.UUID(SUB_UUID).bytes)
        self.assertEqual(pc.btrfs_identity(module, 40, 256),
                         {"kind": "subvolume", "id": "256", "uuid": SUB_UUID})
        self.assertEqual(calls, [("id", 40), ("info", 40, 256)])
        self.refused(pc.btrfs_identity, module, 40, 257, code="directory-bind-incomplete")
        for observed in (0, 1, 255, pc.LAST_FREE + 1, "256", True):
            module.subvolume_id = lambda fd, value=observed: value
            self.refused(pc.btrfs_identity, module, 40, 256)
        module.subvolume_id = lambda fd: 256
        for info in (Info(257, 5, uuid.UUID(SUB_UUID).bytes),
                     Info(256, 0, uuid.UUID(SUB_UUID).bytes),
                     Info(256, 5, bytes(16)), Info(256, 5, SUB_UUID),
                     Info(256, 5, bytes(15)), Info(256, True, uuid.UUID(SUB_UUID).bytes),
                     types.SimpleNamespace(id=256, parent_id=5, uuid=uuid.UUID(SUB_UUID).bytes)):
            module.subvolume_info = lambda fd, ident, value=info: value
            self.refused(pc.btrfs_identity, module, 40, 256)
        module.subvolume_info = mock.Mock(side_effect=OSError("private diagnostic"))
        with self.assertRaises(OSError):
            pc.btrfs_identity(module, 40, 256)

    def test_btrfs_top_level_zero_or_generated_uuid(self):
        Info = collections.namedtuple("SubvolumeInfo", "id parent_id uuid")
        for value in (bytes(16), uuid.UUID(SUB_UUID).bytes):
            module = types.SimpleNamespace(SubvolumeInfo=Info, subvolume_id=lambda fd: 5,
                                           subvolume_info=lambda fd, ident: Info(5, 0, value))
            result = pc.btrfs_identity(module, 40, 256)
            self.assertEqual(result, {"kind": "top-level", "id": "5",
                                      "uuid": SUB_UUID if any(value) else None})

    def test_btrfs_fs_info_zero_flags_and_exact_buffer(self):
        system = pc.System()
        expected = {"kind": "subvolume", "id": "256", "uuid": SUB_UUID}
        calls = []

        def ioctl(fd, request, buffer, mutate):
            self.assertEqual((fd, request, mutate), (40, 0x8400941F, True))
            self.assertEqual(buffer, bytearray(1024))
            buffer[16:32] = uuid.UUID(FS_UUID).bytes
            calls.append(request)
            return 0

        with mock.patch.object(system, "btrfs_api", return_value=object()), \
                mock.patch.object(pc, "btrfs_identity", return_value=expected), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(ino=256)), \
                mock.patch.object(pc.fcntl, "ioctl", side_effect=ioctl):
            self.assertEqual(system.btrfs(40), (expected, FS_UUID))
        self.assertEqual(calls, [0x8400941F])

    def test_fresh_path_requires_inode_and_mount_id(self):
        system = pc.System()
        good = synthetic_stat(stat.S_IFDIR, 0o755)
        for fresh, mids in ((synthetic_stat(stat.S_IFDIR, 0o755, ino=20), [10, 10]),
                            (good, [10, 11])):
            with mock.patch.object(system, "open_canonical", return_value=90), \
                    mock.patch.object(system, "mount_id", side_effect=mids), \
                    mock.patch.object(pc.os, "fstat", side_effect=[good, fresh]), \
                    mock.patch.object(pc.os, "close") as close:
                self.refused(system.bind_directory, 40, "/")
                close.assert_called_once_with(90)

    def test_probe_argv_inherits_only_held_device(self):
        system = pc.System()
        device = {"fd": 80}
        with mock.patch.object(system, "recheck_device") as recheck, \
                mock.patch.object(system, "command", return_value=export(esp_tags())) as command:
            self.assertEqual(system.probe(device), esp_tags())
        self.assertEqual(recheck.call_count, 2)
        args = command.call_args.args[1]
        self.assertEqual(args[:3], ["--probe", "--output", "export"])
        self.assertEqual(args[-2:], ["--", "/proc/self/fd/80"])
        self.assertEqual(args.count("--match-tag"), 5)
        self.assertEqual(command.call_args.kwargs, {"pass_fds": (80,)})
        for forbidden in ("--match-types", "-U", "--list-one", "--match-token"):
            self.assertNotIn(forbidden, args)

    def test_command_exit_diagnostics_output_and_time_limits(self):
        real_popen = subprocess.Popen

        def execute(snippet):
            system = pc.System()

            def popen(_argv, **kwargs):
                return real_popen([sys.executable, "-I", "-S", "-c", snippet], **kwargs)

            with mock.patch.object(system, "open_canonical", side_effect=lambda *args: os.open(sys.executable, os.O_RDONLY)), \
                    mock.patch.object(pc.subprocess, "Popen", side_effect=popen):
                return system.command("/usr/bin/blkid", ["fixture-only"])

        for rc, expected in ((2, "unidentified"), (4, "probe-error"), (8, "collision"), (19, "exit")):
            self.refused(execute, "import os; os.write(1,b'TYPE=vfat\\n'); os._exit(" + str(rc) + ")", code=expected)
        self.refused(execute, "import os; os.write(2,b'private diagnostic')", code="diagnostic")
        self.refused(execute, "import os; os.write(1,b'x'*200000)", code="byte-limit")
        self.refused(execute, "import os; os.write(2,b'x'*20000)", code="byte-limit")
        with mock.patch.object(pc, "COMMAND_SECONDS", 0.05):
            self.refused(execute, "import time; time.sleep(2)", code="timeout")
        self.assertEqual(execute("import os; os.write(1,b'fixture output')"), b"fixture output")

    def test_inventory_scan_checks_coverage_and_parent_omissions(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.system = pc.System()
        rows = {(8, 0): {"number": (8, 0), "parent": None, "partition": None},
                (8, 1): {"number": (8, 1), "parent": (8, 0), "partition": (1, 2048, 1024)}}
        with mock.patch.object(inventory, "names", side_effect=[{"8:0", "8:1"}, {"8:0"}]), \
                mock.patch.object(inventory, "row", side_effect=lambda n: rows[pc.devnum(n)]):
            self.refused(inventory.scan, code="enumeration-drift")
        with mock.patch.object(inventory, "names", return_value={"8:1"}), \
                mock.patch.object(inventory, "row", return_value=rows[(8, 1)]):
            self.refused(inventory.scan, code="parent-missing")
        with mock.patch.object(inventory, "names", side_effect=OSError("partial scan")):
            with self.assertRaises(OSError):
                inventory.scan()

    def test_inventory_finish_ignores_unrelated_disk_drift(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.system = pc.System()
        partition = {"partition": (1, 2048, 1024), "parent": (8, 0)}
        inventory.rows = {(8, 0): {"partition": None}, (8, 1): partition,
                          (8, 16): {"partition": None, "identity": 10}}
        inventory.devices = {(8, 0): {"number": (8, 0)}, (8, 1): {"number": (8, 1)}}
        updated = copy.deepcopy(inventory.rows)
        updated[(8, 16)]["identity"] = 11
        evidence = {(8, 1): pc.partition_identity(esp_tags())}
        with mock.patch.object(inventory, "scan", return_value=updated), \
                mock.patch.object(inventory, "partitions", return_value=evidence), \
                mock.patch.object(inventory.system, "recheck_device") as check:
            inventory.finish(evidence)
            self.assertEqual(check.call_args_list, [mock.call({"number": (8, 0)}), mock.call({"number": (8, 1)})] * 2)
        for change in (lambda r: r.pop((8, 1)),
                       lambda r: r.update({(8, 2): partition}),
                       lambda r: r[(8, 1)].update(parent=(8, 16))):
            altered = copy.deepcopy(updated)
            change(altered)
            with mock.patch.object(inventory, "scan", return_value=altered):
                self.refused(inventory.finish, evidence, code="partition-drift")

    def test_inventory_partition_probes_hold_parent_before_and_after(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.rows = {(8, 0): {"partition": None},
                          (8, 1): {"partition": (1, 2048, 1024), "parent": (8, 0)},
                          (8, 2): {"partition": (2, 4096, 1024), "parent": (8, 0)}}
        events = []
        inventory.system = types.SimpleNamespace(probe=lambda n: events.append(("probe", n)) or
                                                  esp_tags(PART_ENTRY_UUID=PART_UUID if n == (8, 1) else OTHER_UUID),
                                                  charge=lambda _n: None)
        with mock.patch.object(inventory, "bind", side_effect=lambda n: events.append(("bind", n)) or n), \
                mock.patch.object(inventory, "check_row", side_effect=lambda n: events.append(("check", n))):
            result = inventory.partitions()
        self.assertEqual(set(result), {(8, 1), (8, 2)})
        for index, event in enumerate(events):
            if event[0] == "probe":
                self.assertEqual(events[index - 2], ("check", (8, 0)))
                self.assertEqual(events[index + 1], ("check", event[1]))
                self.assertEqual(events[index + 2], ("check", (8, 0)))

    def test_inventory_names_checked_eof_and_row_limit(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.system, inventory.fd = pc.System(), 90
        entry = types.SimpleNamespace(name="8:1", is_symlink=lambda: True)

        @contextlib.contextmanager
        def broken(_fd):
            def rows():
                yield entry
                raise OSError("read failure after first row")
            yield rows()

        with mock.patch.object(pc.os, "scandir", side_effect=broken):
            with self.assertRaises(OSError):
                inventory.names()
        with mock.patch.object(pc.os, "scandir", return_value=contextlib.nullcontext(iter([entry]))), \
                mock.patch.object(pc, "MAX_DEVICES", 0):
            self.refused(inventory.names, code="row-limit")

    def test_inventory_row_exact_names_devnums_type_and_partition(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.fd, inventory.mid = 90, 30
        inventory.system = pc.System()
        attrs = {"dev": "8:1\n", "uevent": b"MAJOR=8\nMINOR=1\nDEVNAME=sda1\nDEVTYPE=partition\n",
                 "partition": "1\n", "start": "2048\n", "size": "1024\n"}

        def run(updates=None):
            values = dict(attrs)
            values.update(updates or {})
            with mock.patch.object(inventory.system, "resolve_owned", return_value="/sys/devices/disk/sda/sda1"), \
                    mock.patch.object(inventory.system, "open_canonical", side_effect=[91, 92]), \
                    mock.patch.object(inventory.system, "mount_id", return_value=30), \
                    mock.patch.object(inventory, "attribute", side_effect=lambda fd, name, **kw: "8:0\n" if fd == 92 else values[name]), \
                    mock.patch.object(pc.os, "stat", return_value=synthetic_stat(stat.S_IFLNK, 0o777)), \
                    mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(stat.S_IFDIR, 0o755)), \
                    mock.patch.object(pc.os, "close"):
                return inventory.row("8:1")

        self.assertEqual(run()["partition"], (1, 2048, 1024))
        for change in ({"dev": "8:2\n"}, {"partition": None}, {"size": "0\n"},
                       {"uevent": attrs["uevent"].replace(b"sda1", b"sdb1")},
                       {"uevent": attrs["uevent"].replace(b"MINOR=1", b"MINOR=2")},
                       {"uevent": attrs["uevent"].replace(b"partition", b"disk")},
                       {"uevent": attrs["uevent"] + b"DEVNAME=sda1\n"},
                       {"uevent": attrs["uevent"] + b"PARTN=2\n"}):
            self.refused(run, change)
        self.assertEqual(run({"uevent": attrs["uevent"] + b"PARTN=1\nPARTNAME=\xff\x00\t\rlabel\\nDEVTYPE=disk\n"})["partition"],
                         (1, 2048, 1024))

    def test_uevent_unused_label_bytes_do_not_create_authority(self):
        required = b"MAJOR=8\nMINOR=1\nDEVNAME=sda1\nDEVTYPE=partition\nPARTN=1\n"
        expected = pc.parse_uevent(required)
        for label in ("Windows 测试".encode(), b"\xff\xfe", b"raw\t\r\x00label", b"line\\nDEVTYPE=disk", b"x=MAJOR=999",
                      b"first line\n\xff\xfe unneeded continuation\nlast label line"):
            self.assertEqual(pc.parse_uevent(required + b"PARTNAME=" + label + b"\n"), expected)
        self.assertEqual(pc.parse_uevent(required + b"PARTNAME=one\nPARTNAME=two\n"), expected)
        for key in (b"MAJOR", b"MINOR", b"DEVNAME", b"DEVTYPE", b"PARTN"):
            self.refused(pc.parse_uevent, required + b"PARTNAME=label\n" + key + b"=1\n")
        for bad in (required[:-1], b"unframed data\n" + required, required.replace(b"MAJOR=8\n", b""),
                    required.replace(b"DEVTYPE=partition", b"DEVTYPE=unknown"),
                    required.replace(b"MINOR=1", b"MINOR=01"),
                    required.replace(b"DEVNAME=sda1", b"DEVNAME=../sda1"),
                    required.replace(b"PARTN=1", b"PARTN=01")):
            self.refused(pc.parse_uevent, bad)

    def test_mapped_partition_is_not_silently_omitted(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.fd, inventory.mid = 90, 30
        inventory.system = pc.System()
        attrs = {"dev": "253:1\n", "uevent": b"MAJOR=253\nMINOR=1\nDEVNAME=dm-1\nDEVTYPE=disk\n",
                  "partition": None, "dm/uuid": b"part1-mpath-fixture\n"}
        with mock.patch.object(inventory.system, "resolve_owned", return_value="/sys/devices/virtual/block/dm-1"), \
                mock.patch.object(inventory.system, "open_canonical", return_value=91), \
                mock.patch.object(inventory.system, "mount_id", return_value=30), \
                mock.patch.object(inventory, "attribute", side_effect=lambda fd, name, **kw: attrs[name]), \
                mock.patch.object(pc.os, "stat", return_value=synthetic_stat(stat.S_IFLNK, 0o777)), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(stat.S_IFDIR, 0o755)), \
                mock.patch.object(pc.os, "close"):
            self.refused(inventory.row, "253:1", code="mapped-partition-incomplete")
            attrs["dm/uuid"] = b"LVM-public-fixture\n"
            self.assertIsNone(inventory.row("253:1")["partition"])
            attrs["dm/uuid"] = b"CRYPT-LUKS2-public-fixture\n"
            self.assertIsNone(inventory.row("253:1")["partition"])

    def test_dm_uuid_suffix_is_opaque_but_partition_prefix_still_blocks(self):
        inventory = pc.Inventory.__new__(pc.Inventory)
        inventory.fd, inventory.mid = 90, 30
        inventory.system = pc.System()
        data = {"dev": "253:1\n", "uevent": b"MAJOR=253\nMINOR=1\nDEVNAME=dm-1\nDEVTYPE=disk\n",
                "partition": None, "dm/uuid": b"CRYPT-LUKS2-\xff\xfe\x7f\x01\n"}
        with mock.patch.object(inventory.system, "resolve_owned", return_value="/sys/devices/virtual/block/dm-1"), \
                mock.patch.object(inventory.system, "open_canonical", return_value=91), \
                mock.patch.object(inventory.system, "mount_id", return_value=30), \
                mock.patch.object(inventory, "attribute", side_effect=lambda fd, name, **kw: data[name]) as attribute, \
                mock.patch.object(pc.os, "stat", return_value=synthetic_stat(stat.S_IFLNK, 0o777)), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(stat.S_IFDIR, 0o755)), \
                mock.patch.object(pc.os, "close"):
            row = inventory.row("253:1")
            self.assertIsNone(row["partition"])
            self.assertNotIn("CRYPT", json.dumps(row))
            self.assertIn(mock.call(91, "dm/uuid", raw=True), attribute.call_args_list)
            for value in (b"part1-\xff\n", b"PART25-\xfe\x01\n"):
                data["dm/uuid"] = value
                self.refused(inventory.row, "253:1", code="mapped-partition-incomplete")
            data["dm/uuid"] = b"CRYPT-LUKS2-\xff"
            self.refused(inventory.row, "253:1", code="mapped-classification")
            attribute.side_effect = OSError("fixture attribute read failure")
            with self.assertRaises(OSError):
                inventory.row("253:1")

    def test_machine_id_bounded_public_owned_read_and_link_resolution(self):
        system = pc.System()
        closed = []
        with mock.patch.object(system, "resolve_owned", return_value="/var/lib/dbus/machine-id") as resolved, \
                mock.patch.object(system, "open_canonical", side_effect=[91, 92]), \
                mock.patch.object(system, "read_fd", return_value=MACHINE_ID.encode() + b"\n"), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(size=33)), \
                mock.patch.object(pc.os, "close", side_effect=closed.append):
            self.assertEqual(system.machine_id(40), MACHINE_ID)
        self.assertEqual(resolved.call_args_list, [mock.call("/etc/machine-id", "machine-id", 40)] * 2)
        self.assertEqual(closed, [92, 91])
        for data in (b"0" * 32, b"a" * 31, b"A" * 32, b"a" * 32 + b"\n\n", b"uninitialized\n"):
            with mock.patch.object(system, "resolve_owned", return_value="/etc/machine-id"), \
                    mock.patch.object(system, "open_canonical", return_value=91), \
                    mock.patch.object(system, "read_fd", return_value=data), \
                    mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(size=len(data))), \
                    mock.patch.object(pc.os, "close"):
                self.refused(system.machine_id, 40)

    def test_machine_id_links_stay_in_selected_fixture_root(self):
        # Root-ownership metadata is the only replacement. All opens, link
        # traversal, pread and before/after identity checks use actual fixture
        # files beneath a supplied FD, with no host root path traversal.
        with tempfile.TemporaryDirectory(prefix="context-links.", dir=SCRATCH) as directory:
            root = Path(directory)
            (root / "etc").mkdir()
            (root / "var").mkdir()
            (root / "var" / "public-id").write_bytes(MACHINE_ID.encode() + b"\n")
            (root / "etc" / "machine-id").symlink_to("/var/public-id")
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            real_stat, real_fstat = os.stat, os.fstat

            def owned(st):
                values = {name: getattr(st, name) for name in
                          ("st_dev", "st_ino", "st_mode", "st_gid", "st_rdev", "st_size", "st_mtime_ns", "st_ctime_ns")}
                values["st_uid"] = 0
                return types.SimpleNamespace(**values)

            try:
                with mock.patch.object(pc.os, "stat", side_effect=lambda *a, **kw: owned(real_stat(*a, **kw))), \
                        mock.patch.object(pc.os, "fstat", side_effect=lambda n: owned(real_fstat(n))):
                    self.assertEqual(pc.System().machine_id(fd), MACHINE_ID)
                (root / "etc" / "machine-id").unlink()
                (root / "etc" / "machine-id").symlink_to("../../outside")
                with mock.patch.object(pc.os, "stat", side_effect=lambda *a, **kw: owned(real_stat(*a, **kw))), \
                        mock.patch.object(pc.os, "fstat", side_effect=lambda n: owned(real_fstat(n))):
                    self.refused(pc.System().machine_id, fd, code="link-scope")
                self.assertTrue(stat.S_ISDIR(real_fstat(fd).st_mode))
            finally:
                os.close(fd)

    def test_regular_input_short_read_cannot_hide_suffix(self):
        system = pc.System()
        with mock.patch.object(system, "read_fd", return_value=b"short public data"), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(size=64)), \
                mock.patch.object(system, "command", side_effect=AssertionError("partial read must not validate")):
            self.refused(system.certificate, 42, code="drift")
        with mock.patch.object(system, "resolve_owned", return_value="/etc/machine-id"), \
                mock.patch.object(system, "open_canonical", return_value=91), \
                mock.patch.object(system, "read_fd", return_value=MACHINE_ID.encode()), \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat(size=33)), \
                mock.patch.object(pc.os, "close"):
            self.refused(system.machine_id, 40, code="drift")

    def test_byte_limit_and_supplied_descriptor_position_preserved(self):
        with tempfile.TemporaryFile(dir=SCRATCH) as file:
            file.write(b"public-fixture")
            file.seek(5)
            system = pc.System()
            self.assertEqual(system.read_fd(file.fileno(), 100, "fixture", positional=True), b"public-fixture")
            self.assertEqual(file.tell(), 5)
            self.refused(system.read_fd, file.fileno(), 3, "fixture", True, code="byte-limit")
            system.close()
            self.assertEqual(file.tell(), 5)
        system = pc.System()
        with mock.patch.object(pc, "MAX_TOTAL_BYTES", 1):
            self.refused(system.charge, 2, code="byte-limit")

    def test_import_isolation_extension_only_and_no_site_search(self):
        system = pc.System()
        info = type("SubvolumeInfo", (), {"__module__": "btrfsutil"})
        suffix = pc.importlib.machinery.EXTENSION_SUFFIXES[0]
        path = "/fixture/platlib/btrfsutil" + suffix
        fake = types.SimpleNamespace(__file__=path, subvolume_id=abs,
                                     subvolume_info=abs, SubvolumeInfo=info)
        original_path = list(sys.path)
        with mock.patch.object(pc.sysconfig, "get_path", return_value="/fixture/platlib"), \
                mock.patch.object(pc.sysconfig, "get_config_var", return_value=suffix), \
                mock.patch.object(system, "open_canonical", side_effect=[91, 92]) as opened, \
                mock.patch.object(pc.os, "fstat", return_value=synthetic_stat()), \
                mock.patch.object(pc.os, "close"), \
                mock.patch.object(pc.importlib.machinery, "ExtensionFileLoader") as loader, \
                mock.patch.object(pc.importlib.util, "spec_from_file_location", return_value=object()), \
                mock.patch.object(pc.importlib.util, "module_from_spec", return_value=fake), \
                mock.patch.object(pc.importlib.machinery.PathFinder, "find_spec", side_effect=AssertionError("ambient search")):
            self.assertIs(system.btrfs_api(), fake)
            loader.assert_called_once_with("btrfsutil", path)
            self.assertEqual(opened.call_args_list, [mock.call(path, stat.S_IFREG, "btrfs-api")] * 2)
            fake.subvolume_id = lambda fd: 256
            opened.side_effect = [91]
            self.refused(system.btrfs_api, code="contract")
        self.assertEqual(sys.path, original_path)
        with mock.patch.object(pc.sys, "flags", types.SimpleNamespace(isolated=0, no_site=0, ignore_environment=0)), \
                mock.patch.object(system, "open_canonical", side_effect=AssertionError("must refuse first")):
            self.refused(system.btrfs_api, code="isolation")

    def test_real_sysconfig_initialization_cannot_execute_environment_override(self):
        # Fresh -I -S children exercise actual stock sysconfig initialization.
        # The positive control proves the fixture payload really is reachable
        # through each override, rather than passing on an already-warm cache.
        with tempfile.TemporaryDirectory(prefix="context-sysconfig.", dir=SCRATCH) as directory:
            root = Path(directory)
            sentinel = root / "executed"
            default_name = f"_sysconfigdata_{sys.abiflags}_{sys.platform}_{sys.implementation._multiarch}"
            payload = ("import sys\n"
                       f"with open({str(sentinel)!r}, 'w') as output: output.write('fixture executed')\n"
                       "build_time_vars = {'prefix': sys.base_prefix, 'exec_prefix': sys.base_exec_prefix,\n"
                       "                   'EXT_SUFFIX': '.fixture-invalid.so'}\n")
            for name in ("_publication_context_injected", default_name):
                (root / (name + ".py")).write_text(payload)
            preamble = ("import sys\n"
                        "sys.dont_write_bytecode = True\n"
                        "assert sys.flags.isolated and sys.flags.no_site and sys.flags.ignore_environment\n"
                        "assert 'sysconfig' not in sys.modules\n")
            control = preamble + ("import sysconfig\n"
                                  "sysconfig.get_path('platlib')\n"
                                  "assert sysconfig.get_config_var('EXT_SUFFIX') == '.fixture-invalid.so'\n")
            protected = preamble + (
                "import importlib.util\n"
                f"spec=importlib.util.spec_from_file_location('context_under_test', {str(INSPECTOR)!r})\n"
                "module=importlib.util.module_from_spec(spec)\n"
                "spec.loader.exec_module(module)\n"
                "assert dict(module.os.environ) == module.HELPER_ENV\n"
                "assert module.sysconfig.get_path('platlib').startswith('/')\n"
                "suffix=module.sysconfig.get_config_var('EXT_SUFFIX')\n"
                "assert suffix and suffix != '.fixture-invalid.so'\n"
                "assert module.sysconfig._CONFIG_VARS_INITIALIZED\n")
            for named in (True, False):
                environment = {**pc.HELPER_ENV, "HOME": str(root), "_PYTHON_SYSCONFIGDATA_PATH": str(root)}
                if named:
                    environment["_PYTHON_SYSCONFIGDATA_NAME"] = "_publication_context_injected"
                with self.subTest(named=named):
                    baseline = subprocess.run([sys.executable, "-I", "-S", "-c", control], env=environment,
                                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE, timeout=5)
                    self.assertEqual(baseline.returncode, 0, baseline.stderr.decode("ascii", "replace"))
                    self.assertTrue(sentinel.exists(), "fixture override did not execute in the positive control")
                    sentinel.unlink()
                    checked = subprocess.run([sys.executable, "-I", "-S", "-c", protected], env=environment,
                                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, timeout=5)
                    self.assertEqual(checked.returncode, 0, checked.stderr.decode("ascii", "replace"))
                    self.assertEqual(checked.stdout, b"")
                    self.assertFalse(sentinel.exists(), "helper executed the injected sysconfig module")

    def test_observation_errors_are_generic_and_preserve_inputs(self):
        with mock.patch.object(pc, "System", return_value=FixtureHardware()), \
                mock.patch.object(pc, "collect", side_effect=OSError("RAW PRIVATE INPUT")):
            result = pc.observe(ARGV)
        self.assertFalse(result["complete"])
        self.assertNotIn("RAW", json.dumps(result))
        self.assertEqual(result["error"], {"operation": "observation", "code": "unavailable"})
        with mock.patch.object(pc, "supervised", side_effect=AssertionError("no observation permitted")), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(pc.main(["--bad", "RAW PRIVATE INPUT"]), 1)
        self.assertNotIn("RAW", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["error"]["operation"], "arguments")

    def test_supervisor_bounds_stuck_worker_and_discards_noise(self):
        with mock.patch.object(pc, "observe", side_effect=lambda argv: time.sleep(2)), \
                mock.patch.object(pc, "TOTAL_SECONDS", 0.05):
            start = time.monotonic()
            result = pc.supervised(ARGV)
            self.assertLess(time.monotonic() - start, 1)
            self.assertEqual(result["error"], {"operation": "supervisor", "code": "timeout"})

        def noisy(_argv):
            os.write(2, b"DO NOT EXPOSE ACQUIRED INPUT")
            return {"format": pc.FORMAT, "schema": 1, "complete": True, "context": {}}

        with mock.patch.object(pc, "observe", side_effect=noisy):
            result = pc.supervised(ARGV)
        self.assertEqual(result["error"]["code"], "framing")
        self.assertNotIn("EXPOSE", json.dumps(result))

    def test_supervisor_waits_for_actual_exit_zero_after_closed_output(self):
        expected = pc.collect(FixtureHardware(), ARGS)

        def delayed(_argv):
            pc.write_result(1, expected)
            os.close(1)
            os.close(2)
            time.sleep(0.08)
            os._exit(0)

        start = time.monotonic()
        with mock.patch.object(pc, "observe", side_effect=delayed):
            self.assertEqual(pc.supervised(ARGV), expected)
        self.assertGreaterEqual(time.monotonic() - start, 0.08)

    def test_supervisor_valid_json_cannot_hide_nonzero_or_signal_exit(self):
        expected = pc.collect(FixtureHardware(), ARGS)
        for status in (19, 125, -signal.SIGKILL):
            def bad_exit(_argv):
                pc.write_result(1, expected)
                if status < 0:
                    os.kill(os.getpid(), -status)
                os._exit(status)

            with mock.patch.object(pc, "observe", side_effect=bad_exit):
                result = pc.supervised(ARGV)
            self.assertFalse(result["complete"])
            self.assertEqual(result["error"]["code"], "worker-exit")

    def test_supervisor_closed_output_live_worker_uses_original_deadline(self):
        expected = pc.collect(FixtureHardware(), ARGS)

        def still_live(_argv):
            pc.write_result(1, expected)
            os.close(1)
            os.close(2)
            time.sleep(2)
            os._exit(0)

        start = time.monotonic()
        with mock.patch.object(pc, "observe", side_effect=still_live), \
                mock.patch.object(pc, "TOTAL_SECONDS", 0.05):
            result = pc.supervised(ARGV)
        self.assertEqual(result["error"]["code"], "timeout")
        self.assertLess(time.monotonic() - start, 1)

    def test_supervisor_failure_frame_stays_failure_even_with_exit_zero(self):
        expected = pc.failure("coverage", "unknown-scheme")

        def failed(_argv):
            pc.write_result(1, expected)
            os._exit(0)

        with mock.patch.object(pc, "observe", side_effect=failed):
            self.assertEqual(pc.supervised(ARGV), expected)

    def test_supervisor_strict_frame_mode_types_duplicates_and_trailing_data(self):
        valid = pc.collect(FixtureHardware(), ARGS)
        wire = pc.encode_result(valid)
        malformed = [wire + wire, wire[:-1], wire + b"raw-input", b" " + wire,
                     wire.replace(b'"schema":1', b'"schema":1,"schema":1', 1),
                     wire.replace(b'"schema":1', b'"schema":true', 1),
                     wire.replace(b'"complete":true', b'"complete":1', 1),
                     wire.replace(b'"schema_version":1', b'"schema_version":true'),
                     wire.replace(b'"subvolume":null', b'"subvolume":NaN'),
                     pc.encode_result({**valid, "unneeded": "raw-input"}),
                     pc.encode_result({**valid, "context": {}}),
                     pc.encode_result({"format": pc.FORMAT + "-api", "schema": 1,
                                       "complete": True, "api": "btrfsutil-fd-explicit-id-v1"})]
        for data in malformed:
            def invalid(_argv):
                os.write(1, data)
                os._exit(0)

            with mock.patch.object(pc, "observe", side_effect=invalid):
                result = pc.supervised(ARGV)
            self.assertEqual(result["error"]["code"], "framing")
            self.assertNotIn("raw-input", json.dumps(result))

    def test_no_signaling_after_reap_or_unknown_wait_ownership(self):
        child = pc.OwnedChild(12345, group=True)
        with mock.patch.object(pc.os, "waitpid", return_value=(12345, 0)), \
                mock.patch.object(pc.os, "kill") as kill, mock.patch.object(pc.os, "killpg") as killpg:
            self.assertEqual(child.reap(), 0)
            child.cleanup()
            kill.assert_not_called()
            killpg.assert_not_called()
        child = pc.OwnedChild(12345, group=True)
        with mock.patch.object(pc.os, "waitid", side_effect=ChildProcessError()), \
                mock.patch.object(pc.os, "kill") as kill, mock.patch.object(pc.os, "killpg") as killpg:
            self.refused(child.kill, code="child-ownership")
            kill.assert_not_called()
            killpg.assert_not_called()

    def run_supervision_fixture(self, mode):
        completed = subprocess.run([sys.executable, "-I", "-S", __file__, str(INSPECTOR), str(SCRATCH),
                                    "--supervision-fixture", mode], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12)
        self.assertEqual(completed.returncode, 0, completed.stderr.decode("ascii", "replace"))
        self.assertEqual(json.loads(completed.stdout), {"complete": True, "mode": mode})

    def test_parent_sigterm_cleans_descendants_and_releases_only_helper_lock_copies(self):
        self.run_supervision_fixture("term")

    def test_parent_sigkill_lifeline_cleans_descendants_and_prunes_high_fds(self):
        self.run_supervision_fixture("kill")

    def test_many_partition_probes_revalidate_complete_coverage_with_one_budget(self):
        def run(step=0.001, late_change=False, unknown=False):
            clock = [0.0]
            counts = collections.Counter()
            rows = {(8, 0): {"number": (8, 0), "partition": None, "parent": None}}
            rows.update({(8, n): {"number": (8, n), "partition": (n, 2048 * n, 1024), "parent": (8, 0)}
                         for n in range(1, 65)})

            def probe(number):
                clock[0] += step
                counts[number] += 1
                result = esp_tags(PART_ENTRY_UUID=str(uuid.UUID(int=number[1])))
                if number == (8, 64):
                    if late_change and counts[number] == 2:
                        result["PART_ENTRY_UUID"] = PART_UUID
                    if unknown:
                        result.pop("PART_ENTRY_SCHEME")
                return result

            with mock.patch.object(pc.time, "monotonic", side_effect=lambda: clock[0]), \
                    mock.patch.object(pc, "TOTAL_SECONDS", 1):
                inventory = pc.Inventory.__new__(pc.Inventory)
                inventory.system = pc.System()
                inventory.devices = {}
                with mock.patch.object(inventory, "names", return_value={str(a) + ":" + str(b) for a, b in rows}), \
                        mock.patch.object(inventory, "row", side_effect=lambda name: rows[pc.devnum(name)]), \
                        mock.patch.object(inventory, "bind", side_effect=lambda number: number), \
                        mock.patch.object(inventory, "check_row"), \
                        mock.patch.object(inventory.system, "probe", side_effect=probe):
                    inventory.rows = inventory.scan()
                    first = inventory.partitions()
                    inventory.finish(first)
                    self.assertEqual(len(first), 64)
                    self.assertEqual(set(counts.values()), {2})
        run()
        self.refused(run, 0.001, True, code="identity-drift")
        self.refused(run, 0.001, False, True, code="unknown-scheme")
        self.refused(run, 0.02, code="timeout")


class PublicCertificateContract(Contract):
    # Inherit only the shared assertion helper, not the full case set.
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="publication-context.", dir=SCRATCH)
        cls.root = Path(cls.temporary.name)
        cls.home = cls.root / "home"
        cls.home.mkdir(mode=0o700)
        cls.environment = {"LC_ALL": "C", "PATH": "/usr/bin", "HOME": str(cls.home),
                           "XDG_CONFIG_HOME": str(cls.home), "HISTFILE": "/dev/null",
                           "OPENSSL_CONF": "/dev/null"}
        public = cls.root / "public.pem"
        ephemeral = cls.root / "ephemeral-key"
        try:
            result = subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                                     "-noenc", "-subj", "/CN=OmaSecBoot disposable fixture",
                                     "-days", "1", "-keyout", str(ephemeral), "-out", str(public)],
                                    env=cls.environment, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
            if result.returncode != 0:
                raise AssertionError("fixture certificate generation failed")
        finally:
            ephemeral.unlink(missing_ok=True)
        cls.pem = public.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def real_command(self, system):
        # Production command framing/execution remains real; executable path
        # custody is a fixture seam, not a host control-directory observation.
        return mock.patch.object(system, "open_canonical",
                                 side_effect=lambda path, kind, op: os.open("/usr/bin/openssl", os.O_RDONLY))

    def certificate(self, data):
        system = pc.System()
        st = synthetic_stat(size=len(data))
        with mock.patch.object(system, "read_fd", return_value=data), \
                mock.patch.object(pc.os, "fstat", return_value=st), \
                self.real_command(system):
            # command() also tests executable mode. Preserve this real parser
            # while the supplied certificate FD remains entirely synthetic.
            st.st_mode |= 0o111
            return system.certificate(42)

    def test_public_full_der_fingerprint_reformatting(self):
        der = pc.pem_der(self.pem)
        encoded = base64.b64encode(der)
        reformatted = (b"\r\n-----BEGIN CERTIFICATE-----\r\n" +
                       b"\r\n".join(encoded[i:i + 48] for i in range(0, len(encoded), 48)) +
                       b"\r\n-----END CERTIFICATE-----\r\n")
        expected = hashlib.sha256(der).hexdigest()
        self.assertEqual(self.certificate(self.pem), expected)
        self.assertEqual(self.certificate(reformatted), expected)
        # Change only certificate signature bytes. They are part of the full
        # DER identity, unlike an SPKI/key-only fingerprint. x509's syntax
        # roundtrip is deliberately separate from signature/keypair validation.
        changed = der[:-1] + bytes((der[-1] ^ 1,))
        replacement = (b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(changed) +
                       b"\n-----END CERTIFICATE-----\n")
        self.assertEqual(self.certificate(replacement), hashlib.sha256(changed).hexdigest())
        self.assertNotEqual(self.certificate(replacement), expected)

    def test_public_pem_extra_objects_junk_and_base64_rejected(self):
        for data in (self.pem + self.pem, b"junk" + self.pem, self.pem + b"junk",
                     self.pem.replace(b"CERTIFICATE", b"PRIVATE KEY"),
                     self.pem.replace(b"-----END", b"!-----END"),
                     b"-----BEGIN CERTIFICATE-----\nYR==\n-----END CERTIFICATE-----\n"):
            self.refused(pc.pem_der, data)

    def test_public_der_trailing_data_and_invalid_der_rejected(self):
        for der in (pc.pem_der(self.pem) + b"trailing", b"not a certificate"):
            data = (b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der) +
                    b"\n-----END CERTIFICATE-----\n")
            self.refused(self.certificate, data)


def suite():
    result = unittest.defaultTestLoader.loadTestsFromTestCase(Contract)
    for name in ("test_public_full_der_fingerprint_reformatting",
                 "test_public_pem_extra_objects_junk_and_base64_rejected",
                 "test_public_der_trailing_data_and_invalid_der_rejected"):
        result.addTest(PublicCertificateContract(name))
    return result


def supervision_fixture(mode):
    """Real process-tree/lock contract, entirely inside this disposable driver.

    Becoming a child subreaper applies only to this driver process. pidfds and
    waitpid observe/reap only its spawned fixture tree; no procfs or host process
    inventory is read. The observer and command bodies are explicit test seams.
    """
    import errno
    import fcntl
    import resource
    import selectors

    if mode not in ("term", "kill"):
        raise AssertionError("unknown fixture mode")
    libc = pc.ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER, driver only
        raise AssertionError("fixture subreaper unavailable")
    with tempfile.TemporaryDirectory(prefix="context-supervision.", dir=SCRATCH) as directory:
        root = Path(directory)
        (root / "esp").mkdir()
        (root / "public.pem").write_bytes(b"public fixture placeholder\n")
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        esp_fd = os.open(root / "esp", os.O_RDONLY | os.O_DIRECTORY)
        certificate_fd = os.open(root / "public.pem", os.O_RDONLY)
        supplied = {"root_fd": root_fd, "esp_fd": esp_fd, "certificate_fd": certificate_fd}
        lock_paths = (root / "boot-lock", root / "repair-lock")
        locks = [os.open(path, os.O_RDWR | os.O_CREAT, 0o600) for path in lock_paths]
        for fd in locks:
            fcntl.flock(fd, fcntl.LOCK_EX)
        argv = ["--root-fd", str(root_fd), "--esp-fd", str(esp_fd), "--certificate-fd", str(certificate_fd),
                "--root-path", str(root), "--esp-path", str(root / "esp"),
                "--config-path", str(root / "esp" / "limine.conf")]
        worker_ready, command_ready = root / "worker-ready", root / "command-ready"
        command_code = (
            "import os,time,json; from pathlib import Path\n"
            "descendant=os.fork()\n"
            "if descendant == 0:\n"
            "    time.sleep(10); os._exit(0)\n"
            f"Path({str(command_ready)!r}).write_text(json.dumps({{'command':os.getpid(),'descendant':descendant}}))\n"
            "time.sleep(10)\n")
        real_popen = subprocess.Popen

        def observe_fixture(_argv):
            for fd in (200, 201, 9000):
                try:
                    fcntl.fcntl(fd, fcntl.F_GETFD)
                except OSError as error:
                    assert error.errno == errno.EBADF
                else:
                    raise AssertionError("irrelevant inherited fixture descriptor survived")
            for name, fd in supplied.items():
                kind = stat.S_IFREG if name == "certificate_fd" else stat.S_IFDIR
                assert stat.S_IFMT(os.fstat(fd).st_mode) == kind
            worker_ready.write_text(json.dumps({"worker": os.getpid(), "guardian": os.getppid()}))
            system = pc.System()

            def launch(_command, **kwargs):
                return real_popen([sys.executable, "-I", "-S", "-c", command_code], **kwargs)

            with mock.patch.object(system, "open_canonical", side_effect=lambda *_args: os.open(sys.executable, os.O_RDONLY)), \
                    mock.patch.object(pc.subprocess, "Popen", side_effect=launch):
                system.command("/usr/bin/blkid", ["fixture-only"])
            raise AssertionError("fixture command unexpectedly returned")

        helper = os.fork()
        if helper == 0:
            try:
                log = os.open(root / "helper-output", os.O_WRONLY | os.O_CREAT, 0o600)
                os.dup2(log, 1)
                os.dup2(log, 2)
                os.dup2(locks[0], 200)
                os.dup2(locks[1], 201)
                os.dup2(locks[0], 9000)
                _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
                resource.setrlimit(resource.RLIMIT_NOFILE, (512, hard))
                with mock.patch.object(pc, "observe", side_effect=observe_fixture), \
                        mock.patch.object(pc, "TOTAL_SECONDS", 5):
                    result = pc.main(argv)
                os._exit(result)
            except BaseException:
                os._exit(126)

        pidfds = {helper: os.pidfd_open(helper)}
        independent = []
        try:
            deadline = time.monotonic() + 3
            reports = None
            while time.monotonic() < deadline:
                try:
                    reports = {**json.loads(worker_ready.read_bytes()), **json.loads(command_ready.read_bytes())}
                    break
                except (FileNotFoundError, json.JSONDecodeError):
                    time.sleep(0.01)
            if reports is None:
                raise AssertionError("fixture worker/command did not become ready")
            for pid in reports.values():
                pidfds[pid] = os.pidfd_open(pid)
            # Closing copies must never unlock the calling process's OFDs.
            for path in lock_paths:
                fd = os.open(path, os.O_RDWR)
                independent.append(fd)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("helper unlocked the caller's OFD")
            for fd in locks:
                os.close(fd)
            locks.clear()
            # Both locks must become available while the worker is still live,
            # proving pruning in the parent, guardian, worker and command tree,
            # including the copy above the helper's lowered descriptor limit.
            for fd in independent:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            signal.pidfd_send_signal(pidfds[helper], signal.SIGTERM if mode == "term" else signal.SIGKILL)
            deadline = time.monotonic() + 3
            with selectors.DefaultSelector() as selector:
                for pid, fd in pidfds.items():
                    selector.register(fd, selectors.EVENT_READ, pid)
                while selector.get_map() and time.monotonic() < deadline:
                    for key, _ in selector.select(0.02):
                        selector.unregister(key.fd)
                if selector.get_map():
                    raise AssertionError("fixture descendants survived parent termination")
            statuses = {}
            while time.monotonic() < deadline:
                try:
                    pid, status = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if pid:
                    statuses[pid] = status
                else:
                    time.sleep(0.01)
            else:
                raise AssertionError("fixture child collection exceeded its cleanup bound")
            if helper not in statuses or statuses[helper] == 0:
                raise AssertionError("terminated helper did not return failure")
        finally:
            # pidfd cleanup remains bound even if a deliberately faulty helper
            # reaps early. No numeric descendant PID can be reused as authority.
            for fd in pidfds.values():
                try:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.close(fd)
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                try:
                    pid, _ = os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    break
                if not pid:
                    time.sleep(0.01)
            for fd in (*locks, *independent, root_fd, esp_fd, certificate_fd):
                os.close(fd)
    print(json.dumps({"complete": True, "mode": mode}))


if __name__ == "__main__":
    require_flags = sys.flags.isolated and sys.flags.no_site and sys.flags.ignore_environment
    if not require_flags:
        raise SystemExit("fixture runner requires python -I -S")
    if len(sys.argv) == 5:
        if sys.argv[3] != "--supervision-fixture":
            raise SystemExit("invalid fixture mode")
        supervision_fixture(sys.argv[4])
        raise SystemExit(0)
    with tempfile.TemporaryDirectory(prefix="publication-context-home.", dir=SCRATCH) as home:
        with mock.patch.dict(os.environ, {"HOME": home, "XDG_CONFIG_HOME": home,
                                          "HISTFILE": "/dev/null"}, clear=True):
            outcome = unittest.TextTestRunner(verbosity=2).run(suite())
    raise SystemExit(0 if outcome.wasSuccessful() else 1)
