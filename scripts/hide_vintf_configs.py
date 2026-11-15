#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# hide_vintf_configs.py - VINTF kernel-config compliance filter.
#
# Android's VINTF (Vendor Interface) validation reads the kernel's built-in
# configuration from /proc/config.gz (CONFIG_IKCONFIG_PROC) and checks it
# against the framework compatibility matrix's <kernel> section. When a
# required CONFIG value differs, the device shows
# "您的设备内部出现了问题。请联系您的设备制造商了解详情" at boot.
#
# This filter rewrites the kernel's compiled-in config (the ikconfig blob)
# so that every CONFIG the compatibility matrix requires is presented with
# the required value. It does NOT change the real kernel configuration or
# the actual compiled features -- only the copy embedded for the framework
# to read. Inspired by cctv18's config.patch (coolapk #66267336).
#
# Usage: cat .config | hide_vintf_configs.py <override-file> > filtered.config
#   override-file format: one "CONFIG_X<TAB>value" per line.

import sys
import os


def load_overrides(path):
    overrides = {}
    if not path or not os.path.exists(path):
        return overrides
    with open(path, "r") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if "\t" in line:
                k, v = line.split("\t", 1)
            elif " " in line:
                k, v = line.split(" ", 1)
            else:
                k, v = line, ""
            overrides[k.strip()] = v.strip()
    return overrides


def format_value(key, value):
    # `key` already carries the CONFIG_ prefix (as stored in the override file
    # and as parsed from the real .config), so write it back verbatim.
    # y/n/m are written bare; everything else (e.g. comma-separated strings)
    # is quoted the same way the real .config stores string options.
    if value in ("y", "n", "m"):
        return "%s=%s" % (key, value)
    if '"' in value or "'" in value:
        return "%s=%s" % (key, value)
    return '%s="%s"' % (key, value)


def main():
    override_path = sys.argv[1] if len(sys.argv) > 1 else ""
    overrides = load_overrides(override_path)

    seen = set()
    out = []
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        s = line.strip()
        if s.startswith("# CONFIG_") and s.endswith(" is not set"):
            key = s[2:s.index(" is not set")]
            seen.add(key)
            if key in overrides:
                out.append(format_value(key, overrides[key]))
            else:
                out.append(line)
            continue
        if s.startswith("CONFIG_") and "=" in s and not s.startswith("#"):
            key, val = s.split("=", 1)
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            seen.add(key)
            if key in overrides and val != overrides[key]:
                out.append(format_value(key, overrides[key]))
            else:
                out.append(line)
            continue
        out.append(line)

    # Append any required CONFIG that is entirely missing from the real config.
    for key in sorted(overrides):
        if key not in seen:
            out.append(format_value(key, overrides[key]))

    sys.stdout.write("\n".join(out))
    if out and not out[-1] == "":
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
