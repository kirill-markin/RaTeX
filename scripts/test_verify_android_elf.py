"""Regression tests for the Android release artifact gate (issue #165)."""

from contextlib import redirect_stdout
import io
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

from verify_android_elf import MACHINES, PT_GNU_RELRO, PT_LOAD, check_elf, verify


def elf(abi, relro=(0x2C4390, 0x3FC70), align=0x4000, offset=0, include_relro=True):
    headers = [(PT_LOAD, 6, offset, 0, 0, 0, 0x400000, align)]
    if include_relro:
        headers.append((PT_GNU_RELRO, 4, 0, relro[0], 0, 0, relro[1], 1))
    data = bytearray(64)
    data[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", data, 16, 3, MACHINES[abi], 1)
    struct.pack_into("<Q", data, 32, 64)
    struct.pack_into("<HHH", data, 52, 64, 56, len(headers))
    return bytes(data) + b"".join(struct.pack("<IIQQQQQQ", *header) for header in headers)


class ElfTests(unittest.TestCase):
    def test_issue_165_both_published_relro_ends(self):
        for abi, relro, end in [
            ("arm64-v8a", (0x2C4390, 0x3DC70), "0x302000"),
            ("x86_64", (0x321610, 0x3D9F0), "0x35f000"),
        ]:
            with self.subTest(abi=abi):
                errors = check_elf(elf(abi, relro=relro), abi)
                self.assertEqual(len(errors), 1)
                self.assertIn(f"end={end}", errors[0])

    def test_aligned_relro_with_unaligned_start_and_align_one(self):
        for abi in MACHINES:
            self.assertEqual(check_elf(elf(abi), abi), [])

    def test_load_alignment_and_congruence(self):
        for kwargs, message in [
            ({"align": 0x1000}, "p_align"),
            ({"align": 0x5000}, "p_align"),
            ({"offset": 1}, "congruent"),
        ]:
            with self.subTest(kwargs=kwargs):
                self.assertIn(message, " ".join(check_elf(elf("arm64-v8a", **kwargs), "arm64-v8a")))

    def test_missing_relro_is_not_a_workaround(self):
        self.assertIn("missing PT_GNU_RELRO", check_elf(elf("x86_64", include_relro=False), "x86_64")[0])

    def test_invalid_elf(self):
        for data in [b"", b"not ELF", elf("x86_64")[:-1], elf("arm64-v8a")]:
            with self.subTest(data=data[:16]):
                self.assertTrue(check_elf(data, "x86_64"))

    def test_directory_and_aar_require_both_abis(self):
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            root = Path(tmp)
            self.assertEqual(len(verify(root)), 2)
            for abi in MACHINES:
                (root / abi).mkdir()
                (root / abi / "libratex_ffi.so").write_bytes(elf(abi))
            self.assertEqual(verify(root), [])
            aar = root / "release.aar"
            with zipfile.ZipFile(aar, "w") as archive:
                for abi in MACHINES:
                    archive.write(root / abi / "libratex_ffi.so", f"jni/{abi}/libratex_ffi.so")
            self.assertEqual(verify(aar), [])
            (root / "x86_64" / "libratex_ffi.so").unlink()
            self.assertIn("missing x86_64/libratex_ffi.so", verify(root))
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr("jni/arm64-v8a/libratex_ffi.so", elf("arm64-v8a"))
            self.assertIn("missing jni/x86_64/libratex_ffi.so", verify(aar))

    def test_aar_checks_additional_shared_libraries(self):
        with tempfile.TemporaryDirectory() as tmp, redirect_stdout(io.StringIO()):
            aar = Path(tmp) / "release.aar"
            with zipfile.ZipFile(aar, "w") as archive:
                for abi in MACHINES:
                    archive.writestr(f"jni/{abi}/libratex_ffi.so", elf(abi))
                archive.writestr("jni/x86_64/libother.so", elf("x86_64", align=0x1000))
            self.assertIn("libother.so", verify(aar)[0])

    def test_cli_exit_status_blocks_invalid_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            command = [sys.executable, str(Path(__file__).with_name("verify_android_elf.py")), tmp]
            missing = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(missing.returncode, 1)
            self.assertIn("missing", missing.stderr)
            for abi in MACHINES:
                (root / abi).mkdir()
                (root / abi / "libratex_ffi.so").write_bytes(elf(abi))
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            (root / "x86_64" / "libratex_ffi.so").write_bytes(
                elf("x86_64", relro=(0x321610, 0x3D9F0))
            )
            invalid = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(invalid.returncode, 1)
            self.assertIn("GNU_RELRO", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
