#!/usr/bin/env python3
"""
imgtools.py — pure-Python image tools used by m0_build.py / setup_image.ps1.

Replaces external binaries (msys2 lz4.exe / simg2img.exe / busybox cpio) with
stdlib-only implementations, so the repo builds with just Python 3.

Implemented:
  * lz4_block_compress / lz4_frame_compress
        - LZ4 legacy frame format (magic 0x184C2102) as produced by
          `lz4 -l -z` (what m0_build.py used). The "legacy" frame is a
          sequence of [4-byte LE size][block]. We emit all-literal blocks —
          valid LZ4, ratio ~1.0, which is fine for a ~2 MB ramdisk segment.
  * lz4_decompress
        - Handles both the LEGACY (0x184C2102) and the STANDARD (0x184D2204)
          frame formats (the init/vendor ramdisks from the image use standard
          frames; the injected segment uses legacy). Implements real LZ4
          block decoding (literals + short/long matches with offset backrefs).
  * unsparse(data) -> raw
        - Android sparse image (magic 0xED26FF3A), chunk types RAW / FILL /
          DONT_CARE / CRC32. Produces the full raw image bytes.
  * sparse_to_file(src, dst)
        - Streams unsparse output to a file (super.img is ~1.5 GB sparse ->
          8+ GB raw; keep memory bounded).
  * cpio_newc_extract(data, dest_dir)
        - newc (070701) cpio archive extraction.

All functions are deterministic and dependency-free (stdlib only).
"""
import os
import struct
import zlib

# -------------------------------------------------------------------------- #
# LZ4                                                                         #
# -------------------------------------------------------------------------- #

LZ4_LEGACY_MAGIC = 0x184C2102
LZ4_STD_MAGIC    = 0x184D2204

_MAX_BLOCK = 4 << 20   # 4 MiB blocks, matches lz4 -l default


def lz4_block_compress_literals(chunk: bytes) -> bytes:
    """Encode one block as a single all-literal sequence (valid LZ4).

    LZ4 block = sequences; the FINAL sequence is literals-only (no match).
    We emit exactly one literal run covering the whole block via an extended
    length token (high nibble 0xF + extension bytes), then no match.
    """
    out = bytearray()
    n = len(chunk)
    out.append(0xF0)                  # token: lit-len=15(extended), match=0
    remaining = n - 15
    if remaining < 0:
        # block shorter than 15 bytes: token holds the exact length
        out[-1] = n << 4
        out.extend(chunk)
        return bytes(out)
    while remaining >= 255:
        out.append(255)
        remaining -= 255
    out.append(remaining)
    out.extend(chunk)
    return bytes(out)


def lz4_legacy_frame_compress(data: bytes) -> bytes:
    """Legacy frame: magic + [size][block]... (all-literal blocks)."""
    out = bytearray(struct.pack("<I", LZ4_LEGACY_MAGIC))
    for off in range(0, len(data), _MAX_BLOCK):
        block = data[off:off + _MAX_BLOCK]
        comp = lz4_block_compress_literals(block)
        out.extend(struct.pack("<I", len(comp)))
        out.extend(comp)
    return bytes(out)


def _decompress_block(block: bytes, out: bytearray) -> None:
    i = 0
    n = len(block)
    while i < n:
        token = block[i]; i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = block[i]; i += 1
                lit += b
                if b != 255: break
        out.extend(block[i:i + lit]); i += lit
        if i >= n:
            break
        # match
        if i + 1 >= n:
            break
        offset = block[i] | (block[i + 1] << 8); i += 2
        mlen = token & 0x0F
        if mlen == 15:
            while True:
                b = block[i]; i += 1
                mlen += b
                if b != 255: break
        mlen += 4
        # copy match (may overlap)
        start = len(out)
        for k in range(mlen):
            out.append(out[start - offset + k])


def lz4_decompress(data: bytes) -> bytes:
    """Decompress LZ4 legacy or standard frame. Returns raw bytes."""
    if len(data) < 4:
        raise ValueError("input too short for LZ4")
    magic = struct.unpack_from("<I", data, 0)[0]
    pos = 4
    if magic == LZ4_STD_MAGIC:
        # standard frame: FLG, BD, optional content-size, [block-size][block]...
        flg = data[pos]; pos += 1
        bd  = data[pos]; pos += 1
        if flg & 0x08:   # content size present (8 bytes)
            pos += 8
        # block size code in BD high nibble
        bs_code = (bd >> 4) & 0x7
        # 4=64KB 5=256KB 6=1MB 7=4MB; we just read sizes per block, ignore.
    elif magic == LZ4_LEGACY_MAGIC:
        pass
    else:
        raise ValueError(f"not an LZ4 frame (magic 0x{magic:08X})")

    out = bytearray()
    while pos + 4 <= len(data):
        size = struct.unpack_from("<I", data, pos)[0]; pos += 4
        if size == 0:
            break  # end mark
        if size & 0x80000000:
            # uncompressed block (high bit set), size = low 31 bits
            raw = data[pos:pos + (size & 0x7FFFFFFF)]
            out.extend(raw)
            pos += (size & 0x7FFFFFFF)
        else:
            _decompress_block(data[pos:pos + size], out)
            pos += size
    return bytes(out)


def lz4_compress(data: bytes) -> bytes:
    """Alias for m0_build.py compatibility: legacy-frame compress."""
    return lz4_legacy_frame_compress(data)


# -------------------------------------------------------------------------- #
# Android sparse image                                                        #
# -------------------------------------------------------------------------- #

SPARSE_MAGIC = 0xED26FF3A
CHUNK_RAW         = 0xCAC1
CHUNK_FILL        = 0xCAC2
CHUNK_DONT_CARE   = 0xCAC3
CHUNK_CRC32       = 0xCAC4


def unsparse(data: bytes) -> bytes:
    """Expand an Android sparse image into full raw bytes."""
    if len(data) < 28:
        raise ValueError("sparse image too short")
    if struct.unpack_from("<I", data, 0)[0] != SPARSE_MAGIC:
        # not sparse — return as-is (already raw)
        return data
    (magic, major, minor, hdr_sz, chunk_hdr_sz, blk_sz, total_blks,
     nchunks, _crc) = struct.unpack_from("<IHHHHIIII", data, 0)
    if major != 1:
        raise ValueError(f"unsupported sparse version {major}.{minor}")
    pos = hdr_sz
    out = bytearray()
    for _ in range(nchunks):
        (chunk_type, _reserved, chunk_sz, total_sz) = struct.unpack_from(
            "<HHII", data, pos)
        pos += chunk_hdr_sz
        if chunk_type == CHUNK_RAW:
            out.extend(data[pos:pos + chunk_sz * blk_sz])
            pos += chunk_sz * blk_sz
        elif chunk_type == CHUNK_FILL:
            fill = data[pos:pos + 4]; pos += 4
            out.extend(fill * (chunk_sz * blk_sz // 4))
        elif chunk_type == CHUNK_DONT_CARE:
            out.extend(b"\x00" * (chunk_sz * blk_sz))
        elif chunk_type == CHUNK_CRC32:
            out.extend(b"\x00" * (chunk_sz * blk_sz))  # crc chunk carries no data
            pos += 4
        else:
            raise ValueError(f"unknown sparse chunk type 0x{chunk_type:04X}")
    return bytes(out)


def sparse_to_file(src_path: str, dst_path: str) -> None:
    """Stream unsparse src (raw or sparse) into dst, bounded memory."""
    with open(src_path, "rb") as src:
        head = src.read(28)
        if len(head) < 28 or struct.unpack_from("<I", head, 0)[0] != SPARSE_MAGIC:
            src.seek(0)
            with open(dst_path, "wb") as dst:
                while True:
                    b = src.read(8 << 20)
                    if not b: break
                    dst.write(b)
            return
        (magic, major, minor, hdr_sz, chsz, blk_sz, total_blks,
         nchunks, _crc) = struct.unpack_from("<IHHHHIIII", head, 0)
        if major != 1:
            raise ValueError(f"unsupported sparse version {major}.{minor}")
        if chsz not in (12, 16):
            raise ValueError(f"unexpected chunk header size {chsz}")
        if chsz == 16:
            # v1.1+ 16-byte header has a 4-byte total_sz; v1.0 12-byte does not.
            pass
        src.seek(hdr_sz)
        with open(dst_path, "wb") as dst:
            for _ in range(nchunks):
                ch = src.read(chsz)
                (ctype, _res, csz) = struct.unpack_from("<HHI", ch, 0)
                if ctype == CHUNK_RAW:
                    dst.write(src.read(csz * blk_sz))
                elif ctype == CHUNK_FILL:
                    fill = src.read(4)
                    dst.write(fill * (csz * blk_sz // 4))
                elif ctype == CHUNK_DONT_CARE:
                    dst.write(b"\x00" * (csz * blk_sz))
                elif ctype == CHUNK_CRC32:
                    src.read(4)
                else:
                    raise ValueError(f"unknown chunk 0x{ctype:04X}")


def simg2img(src_path: str, dst_path: str) -> None:
    """simg2img drop-in: expand sparse src_path -> raw dst_path."""
    sparse_to_file(src_path, dst_path)


# -------------------------------------------------------------------------- #
# cpio newc                                                                   #
# -------------------------------------------------------------------------- #

_NEWC = b"070701"


def cpio_newc_extract(data: bytes, dest_dir: str) -> list:
    """Extract a newc (070701) cpio archive into dest_dir. Returns file list."""
    os.makedirs(dest_dir, exist_ok=True)
    extracted = []
    pos = 0
    n = len(data)
    while pos + 110 <= n:
        if data[pos:pos + 6] != _NEWC:
            break
        magic = data[pos:pos + 6]
        assert magic == _NEWC
        # fixed header is 13 x 8 hex fields = 104 chars + 6 magic
        fields = []
        for f in range(13):
            fields.append(int(data[pos + 6 + f * 8: pos + 6 + (f + 1) * 8], 16))
        ino, mode, uid, gid, nlink, mtime, filesize, devmaj, devmin, \
            rdevmaj, rdevmin, namesize, check = fields
        name_start = pos + 110
        name = data[name_start:name_start + namesize - 1].decode(
            "utf-8", errors="replace")
        data_start = (name_start + namesize + 3) & ~3
        body = data[data_start:data_start + filesize]
        next_pos = (data_start + filesize + 3) & ~3

        if name == "TRAILER!!!":
            break

        # sanitize path (no absolute / traversal)
        rel = name.lstrip("/")
        if ".." in rel.split("/"):
            pos = next_pos
            continue
        dest = os.path.join(dest_dir, rel)
        if mode & 0o170000 == 0o040000:      # directory
            os.makedirs(dest, exist_ok=True)
        elif mode & 0o170000 == 0o120000:    # symlink
            target = body.decode("utf-8", errors="replace")
            if os.path.lexists(dest):
                os.remove(dest)
            os.symlink(target, dest)
        else:                                # regular file (incl. device-ish)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(body)
            if mode & 0o100:                 # executable bit set
                try:
                    os.chmod(dest, mode & 0o777)
                except OSError:
                    pass
        extracted.append(rel)
        pos = next_pos
    return extracted


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "unsparse" and len(sys.argv) == 4:
        simg2img(sys.argv[2], sys.argv[3])
    elif cmd == "lz4d" and len(sys.argv) == 3:
        sys.stdout.buffer.write(lz4_decompress(open(sys.argv[2], "rb").read()))
    else:
        print(__doc__)
        sys.exit(1)