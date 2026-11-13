#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Build an Android DTBO image from the compiled *.dtbo overlays.

The LineageOS sm7250 tree has rules to compile each overlay into a .dtbo,
but no rule that packs them into arch/arm64/boot/dtbo.img.  This tool does
that, using the standard Android dt_table_header / dt_table_entry layout.

Qualcomm bootloaders match overlays with the values found in the overlay
sources' qcom,msm-id / qcom,board-id properties, so they are propagated
into the dt_table_entry id / rev / custom fields.
"""

import argparse
import re
import struct
import sys
from pathlib import Path

DTBO_MAGIC = 0xD7B7AB1E
HEADER_SIZE = 32          # 8 x uint32
ENTRY_SIZE = 32           # 8 x uint32
CELL_RE = re.compile(r"0x[0-9a-fA-F]+|\d+")


def parse_cells(value):
    return [int(x, 0) for x in CELL_RE.findall(value)]


def qcom_ids(dts_path):
    """Return (id, rev, [custom0..3]) read from a Qualcomm overlay source."""
    if not dts_path.exists():
        return 0, 0, [0, 0, 0, 0]
    src = dts_path.read_text(errors="replace")
    msm = re.search(r"qcom,msm-id\s*=\s*([^;]+);", src)
    board = re.search(r"qcom,board-id\s*=\s*([^;]+);", src)
    m = parse_cells(msm.group(1)) if msm else []
    b = parse_cells(board.group(1)) if board else []
    return (
        m[0] if m else 0,
        m[1] if len(m) > 1 else 0,
        [b[0] if b else 0, b[1] if len(b) > 1 else 0, 0, 0],
    )


def overlay_names(makefile, platform):
    """Read the dtbo-$(CONFIG_ARCH_<platform>) += ... list from a Makefile."""
    text = makefile.read_text(errors="replace")
    needle = "dtbo-$(CONFIG_ARCH_%s)" % platform
    pos = text.find(needle)
    if pos < 0:
        raise SystemExit("No %s block in %s" % (needle, makefile))
    block = text[pos:]
    end = block.find("\n\n")
    if end > 0:
        block = block[:end]
    names = re.findall(r"[\w.-]+\.dtbo", block)
    if not names:
        raise SystemExit("No .dtbo entries found in %s block" % needle)
    return names


def align(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def build(dtbo_dir, dts_dir, makefile, platform, out_path, page_size):
    names = overlay_names(makefile, platform)
    entries = []
    for name in names:
        dtbo = dtbo_dir / name
        if not dtbo.exists():
            print("WARN: missing %s, skipped" % name, file=sys.stderr)
            continue
        data = dtbo.read_bytes()
        ident, rev, custom = qcom_ids(dts_dir / (name[:-5] + ".dts"))
        entries.append((data, ident, rev, custom, name))
    if not entries:
        raise SystemExit("No .dtbo files available, refusing to create an empty image")

    entries_offset = HEADER_SIZE
    data_offset = align(HEADER_SIZE + ENTRY_SIZE * len(entries), 4)
    payload = bytearray()
    table = bytearray()
    cursor = data_offset
    for data, ident, rev, custom, name in entries:
        table += struct.pack(
            ">8I", len(data), cursor, ident, rev,
            custom[0], custom[1], custom[2], custom[3],
        )
        payload += data
        payload += b"\0" * (align(len(data), 4) - len(data))
        cursor += align(len(data), 4)
        print("  %-42s size=%-8d id=%-6d rev=%-8d board=%d"
              % (name, len(data), ident, rev, custom[0]))
    total = align(data_offset + len(payload), page_size)
    header = struct.pack(
        ">8I", DTBO_MAGIC, total, HEADER_SIZE, ENTRY_SIZE,
        len(entries), entries_offset, page_size, 0,
    )
    image = header + table + payload
    image += b"\0" * (total - len(image))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(image)
    print("Created %s: %d entries, %d bytes" % (out_path, len(entries), len(image)))


def dump(path):
    raw = path.read_bytes()
    (magic, total, hsize, esize, count, eoff, page, ver) = struct.unpack_from(">8I", raw, 0)
    print("magic=0x%08x total=%d header_size=%d entry_size=%d count=%d "
          "entries_offset=%d page_size=%d version=%d"
          % (magic, total, hsize, esize, count, eoff, page, ver))
    if magic != DTBO_MAGIC:
        raise SystemExit("Not a DTBO image")
    for i in range(count):
        vals = struct.unpack_from(">8I", raw, eoff + i * esize)
        print("  [%2d] size=%-8d offset=%-9d id=%-6d rev=%-8d custom=%s"
              % (i, vals[0], vals[1], vals[2], vals[3], list(vals[4:8])))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("create", help="pack compiled overlays into dtbo.img")
    c.add_argument("--dtbo-dir", type=Path, required=True)
    c.add_argument("--dts-dir", type=Path, required=True)
    c.add_argument("--makefile", type=Path, required=True)
    c.add_argument("--platform", default="LITO")
    c.add_argument("--page-size", type=int, default=4096)
    c.add_argument("--out", type=Path, required=True)

    d = sub.add_parser("dump", help="show the entries of an existing dtbo.img")
    d.add_argument("image", type=Path)

    args = ap.parse_args()
    if args.cmd == "create":
        build(args.dtbo_dir, args.dts_dir, args.makefile, args.platform,
              args.out, args.page_size)
    else:
        dump(args.image)


if __name__ == "__main__":
    main()
