#!/usr/bin/env python3
"""Check 64-bit Android ELF LOAD/RELRO alignment in a jniLibs directory or AAR.

Uses only Python's standard library; no host-specific readelf is required.
This checks ELF layout, not the ZIP alignment of an application's APK.
"""

import argparse
from pathlib import Path
import struct
import sys
import zipfile


PAGE_SIZE = 0x4000
MACHINES = {"arm64-v8a": 183, "x86_64": 62}
PT_LOAD = 1
PT_GNU_RELRO = 0x6474E552


def check_elf(data, abi):
    """Return alignment errors for a little-endian ELF64 shared library."""
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
        return ["expected a little-endian ELF64 header"]
    elf_type, machine = struct.unpack_from("<HH", data, 16)
    if elf_type != 3 or machine != MACHINES[abi]:
        return [f"expected an {abi} ELF shared library"]
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    if phentsize != 56 or not phnum or phoff < 64 or phoff + phentsize * phnum > len(data):
        return ["invalid or truncated ELF program header table"]

    errors = []
    loads = relros = 0
    for index in range(phnum):
        kind, _, offset, vaddr, _, filesz, memsz, align = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + index * phentsize
        )
        if kind == PT_LOAD:
            loads += 1
            if filesz > memsz or offset + filesz > len(data):
                errors.append(f"LOAD[{index}]: invalid segment size")
            if align < PAGE_SIZE or align & (align - 1):
                errors.append(f"LOAD[{index}]: p_align={align:#x}, expected a power of two >= 0x4000")
            if (vaddr - offset) % PAGE_SIZE:
                errors.append(f"LOAD[{index}]: virtual address and file offset are not congruent modulo 0x4000")
        elif kind == PT_GNU_RELRO:
            relros += 1
            end = vaddr + memsz
            if not memsz or end % PAGE_SIZE:
                errors.append(
                    f"GNU_RELRO[{index}]: end={end:#x}, end % 0x4000={end % PAGE_SIZE:#x}"
                )
    if not loads:
        errors.append("missing PT_LOAD")
    if not relros:
        errors.append("missing PT_GNU_RELRO; keep RELRO protection enabled")
    return errors


def verify(path):
    """Check both required ABIs, including any additional .so files they ship."""
    errors = []

    def check(name, data, abi):
        issues = check_elf(data, abi)
        errors.extend(f"{name}: {issue}" for issue in issues)
        if not issues:
            print(f"PASS {name}: LOAD and GNU_RELRO are 16 KB aligned")

    if path.is_dir():
        for abi in MACHINES:
            if not (path / abi / "libratex_ffi.so").is_file():
                errors.append(f"missing {abi}/libratex_ffi.so")
            for library in sorted((path / abi).rglob("*.so")):
                check(str(library), library.read_bytes(), abi)
    else:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            for abi in MACHINES:
                required = f"jni/{abi}/libratex_ffi.so"
                if required not in names:
                    errors.append(f"missing {required}")
                for name in sorted(names):
                    if name.startswith(f"jni/{abi}/") and name.endswith(".so"):
                        if names.count(name) != 1:
                            errors.append(f"duplicate archive entry: {name}")
                        check(name, archive.read(name), abi)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="jniLibs directory or release AAR")
    args = parser.parse_args()
    try:
        errors = verify(args.artifact)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        errors = [str(error)]
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
