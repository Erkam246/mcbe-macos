#!/usr/bin/env python3
"""Add a weak LC_LOAD_DYLIB for the macfix dylib to a thin arm64 Mach-O.

Idempotent: exits cleanly if the load command is already present.

usage: patch_app.py <app>/minecraftpe
"""
import os
import struct
import sys
import tempfile

LC_SEGMENT_64, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB = 0x19, 0xC, 0x80000018
MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
DYLIB = "@executable_path/Frameworks/libmacfix.dylib"


def main():
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())
    if len(data) < 32:
        sys.exit("not a Mach-O file")
    magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<6I", data)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        sys.exit("expected a thin arm64 Mach-O executable")

    off, first_section = 32, len(data)
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8 or size % 8 or off + size > 32 + sizeofcmds:
            sys.exit("malformed load commands")
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            name = data[off + name_off:off + size].split(b"\0")[0].decode()
            if name == DYLIB:
                print("load command already present")
                return
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                sect_off = struct.unpack_from("<I", data, off + 72 + i * 80 + 48)[0]
                if sect_off:
                    first_section = min(first_section, sect_off)
        off += size

    name = DYLIB.encode() + b"\0"
    cmdsize = (24 + len(name) + 7) // 8 * 8
    end = 32 + sizeofcmds
    if end + cmdsize > first_section or any(data[end:end + cmdsize]):
        sys.exit("no free space after the load commands")

    lc = struct.pack("<6I", LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x10000, 0x10000) + name
    data[end:end + cmdsize] = lc.ljust(cmdsize, b"\0")
    struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    # Write beside the original and swap it in, so a failure never leaves a half-written binary.
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, os.stat(path).st_mode)
    os.replace(tmp, path)
    print(f"added weak load command for {DYLIB}")


if __name__ == "__main__":
    main()
