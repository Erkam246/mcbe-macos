#!/usr/bin/env python3
"""Verify a decrypted IPA against the Apple-signed encrypted original.

Apple signs the encrypted pages, so only pages outside each binary's encrypted
range can be checked against the signature; the encrypted range is reported as
unverifiable. Every non-Mach-O file must be byte-identical. The original is
trusted as given: download it from Apple yourself (e.g. with ipatool).

usage: verify_decrypted.py <original.ipa|dir> <decrypted.ipa|dir>
"""
import atexit, hashlib, os, plistlib, shutil, struct, sys, tempfile, zipfile

MH_MAGIC_64, FAT_MAGIC, FAT_MAGIC_64 = 0xFEEDFACF, 0xCAFEBABE, 0xCAFEBABF
LC_CODE_SIGNATURE, LC_ENCRYPTION_INFO_64 = 0x1D, 0x2C
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
HASHES = {1: hashlib.sha1, 2: hashlib.sha256, 3: hashlib.sha256, 4: hashlib.sha384}
# Files a decrypter legitimately drops or rewrites.
IGNORED_DIRS = {"SC_Info", "META-INF"}
IGNORED_FILES = {"iTunesMetadata.plist", "iTunesArtwork"}


def load(path):
    if os.path.isdir(path):
        return path
    out = tempfile.mkdtemp(prefix="ipa-")
    atexit.register(shutil.rmtree, out, ignore_errors=True)
    with zipfile.ZipFile(path) as z:
        z.extractall(out)
    return out


def files(root):
    """Maps relative path to ("file", path) or ("link", target)."""
    res = {}
    for d, dirs, names in os.walk(root):
        dirs[:] = [x for x in dirs if x not in IGNORED_DIRS]
        for n in names + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, n)
            rel = os.path.relpath(p, root)
            if n in IGNORED_FILES:
                continue
            res[rel] = ("link", os.readlink(p)) if os.path.islink(p) else ("file", p)
    return res


def slices(data):
    if len(data) < 32:
        return
    magic = struct.unpack_from(">I", data)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack_from(">I", data, 4)[0]
        for i in range(n):
            if magic == FAT_MAGIC:
                _, _, off, size, _ = struct.unpack_from(">5I", data, 8 + i * 20)
            else:
                _, _, off, size, _, _ = struct.unpack_from(">2I2QII", data, 8 + i * 32)
            yield off, size
    elif struct.unpack_from("<I", data)[0] == MH_MAGIC_64:
        yield 0, len(data)


def parse(data, base):
    """Returns (encryption info (cryptid offset, cryptoff, cryptsize) or None, best CodeDirectory)."""
    ncmds = struct.unpack_from("<I", data, base + 16)[0]
    off, cryptid_off, sig = base + 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == LC_ENCRYPTION_INFO_64:
            cryptoff, cryptsize = struct.unpack_from("<II", data, off + 8)
            cryptid_off = (off + 16, cryptoff, cryptsize)
        elif cmd == LC_CODE_SIGNATURE:
            sig = struct.unpack_from("<II", data, off + 8)
        off += size
    if sig is None:
        raise ValueError("no code signature")
    sb = base + sig[0]
    count = struct.unpack_from(">I", data, sb + 8)[0]
    best = None
    for i in range(count):
        _, boff = struct.unpack_from(">II", data, sb + 12 + i * 8)
        cd = sb + boff
        if struct.unpack_from(">I", data, cd)[0] != CSMAGIC_CODEDIRECTORY:
            continue
        hoff, _, nslots, ncode, climit, hsize, htype, _, pgshift = struct.unpack_from(">IIIIIBBBB", data, cd + 16)
        hashes = [data[cd + hoff + i * hsize: cd + hoff + (i + 1) * hsize] for i in range(ncode)]
        cand = (htype, 1 << pgshift, climit, hashes)
        if best is None or htype > best[0]:
            best = cand
    return cryptid_off, best


def encrypted(data):
    """True if any slice still has a non-zero cryptid."""
    for base, _ in slices(data):
        enc, _ = parse(data, base)
        if enc and struct.unpack_from("<I", data, enc[0])[0]:
            return True
    return False


def verify_macho(orig, dec):
    """Returns (error or None, bytes that could not be verified)."""
    if len(orig) != len(dec):
        return f"size differs ({len(orig)} vs {len(dec)})", 0
    o_sl, d_sl = list(slices(orig)), list(slices(dec))
    if not o_sl or o_sl != d_sl:
        return "slice layout differs", 0
    covered = sorted(o_sl)
    pos = 0
    for base, size in covered + [(len(orig), 0)]:
        if orig[pos:base] != dec[pos:base]:
            return "bytes outside the slices differ", 0
        pos = base + size
    dec = bytearray(dec)
    unverified = 0
    for base, size in o_sl:
        enc, (htype, pg, climit, hashes) = parse(orig, base)
        lo = hi = 0
        if enc is not None:
            cid, cryptoff, cryptsize = enc
            if struct.unpack_from("<I", orig, cid)[0]:
                if struct.unpack_from("<I", dec, cid)[0]:
                    return "still encrypted (cryptid is not 0)", 0
                # Decrypters flip cryptid 1->0; restore it so page 0 hashes as signed.
                dec[cid:cid + 4] = orig[cid:cid + 4]
                lo, hi = cryptoff // pg, (cryptoff + cryptsize + pg - 1) // pg
                # Pages that straddle the encrypted range are skipped below; their
                # plaintext edges must still match the original byte for byte.
                edge_lo, edge_hi = base + lo * pg, base + min(hi * pg, climit)
                crypt_lo, crypt_hi = base + cryptoff, base + cryptoff + cryptsize
                if dec[edge_lo:crypt_lo] != orig[edge_lo:crypt_lo] or dec[crypt_hi:edge_hi] != orig[crypt_hi:edge_hi]:
                    return "bytes beside the encrypted range differ", 0
        h = HASHES[htype]
        for i, want in enumerate(hashes):
            if lo <= i < hi:
                continue
            start = base + i * pg
            page = dec[start:base + min((i + 1) * pg, climit)]
            if h(page).digest()[:len(want)] != want:
                return f"page {i} (offset {start:#x}) does not match Apple's signature", 0
        unverified += cryptsize if hi else 0
        if dec[base + climit:base + size] != orig[base + climit:base + size]:
            return "code signature blob differs", 0
    return None, unverified


def main():
    o_root, d_root = load(sys.argv[1]), load(sys.argv[2])
    o, d = files(o_root), files(d_root)
    bad = [f"extra file: {x}" for x in sorted(d.keys() - o.keys())]
    bad += [f"missing file: {x}" for x in sorted(o.keys() - d.keys())]
    pages, unverified = 0, 0
    for rel in sorted(o.keys() & d.keys()):
        if o[rel][0] == "link" or d[rel][0] == "link":
            if o[rel] != d[rel]:
                bad.append(f"{rel}: link or file type differs")
            continue
        a, b = open(o[rel][1], "rb").read(), open(d[rel][1], "rb").read()
        if a == b:
            if encrypted(a):
                bad.append(f"{rel}: still encrypted (cryptid is not 0)")
            continue
        if list(slices(a)):
            err, n = verify_macho(a, b)
            if err:
                bad.append(f"{rel}: {err}")
            else:
                pages += 1
                unverified += n
                print(f"ok  {rel} (outside encrypted range matches; {n / 2**20:.1f} MiB encrypted range unverifiable)")
        elif rel.endswith(".plist"):
            ka, kb = plistlib.loads(a), plistlib.loads(b)
            diff = sorted(k for k in ka.keys() | kb.keys() if ka.get(k) != kb.get(k))
            bad.append(f"{rel}: plist keys changed {diff}")
        else:
            bad.append(f"{rel}: content differs")
    print(f"\nchecked {len(o)} files, {pages} decrypted Mach-O files; {unverified / 2**20:.1f} MiB of code cannot be checked")
    if bad:
        print("FAIL:\n  " + "\n  ".join(bad))
        sys.exit(1)
    print("PASS: identical to Apple's build outside the encrypted code ranges")


if __name__ == "__main__":
    main()
