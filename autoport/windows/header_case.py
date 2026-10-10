#!/usr/bin/env python3
"""Symlink Windows SDK headers under the spelling the sources use.

Windows is case-insensitive, so sources include <ObjBase.h> while xwin ships
objbase.h. Scans the given source trees for #include names that miss the
SDK include dirs case-sensitively but match case-insensitively, and creates
<out>/<Name.h> -> <real header> for each (subdirectories kept).

  header_case.py --sdk-include DIR [--sdk-include DIR...] --out DIR SRC_DIR...
"""

import argparse
import os
import re
from pathlib import Path

RE_INCLUDE = re.compile(rb'^\s*#\s*include\s*[<"]([^>"]+)[>"]', re.M)
SOURCE_EXT = {".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".c", ".cc", ".cpp", ".cxx"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sdk-include", action="append", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("sources", nargs="+", type=Path)
    args = ap.parse_args()

    # lowercase relative path -> real file, per SDK include dir
    real = {}
    for inc in args.sdk_include:
        for dirpath, _, files in os.walk(inc):
            for f in files:
                full = Path(dirpath) / f
                real.setdefault(str(full.relative_to(inc)).lower(), full)

    wanted = set()
    for src in args.sources:
        for dirpath, _, files in os.walk(src):
            for f in files:
                if Path(f).suffix.lower() not in SOURCE_EXT:
                    continue
                try:
                    text = (Path(dirpath) / f).read_bytes()
                except OSError:
                    continue
                for m in RE_INCLUDE.finditer(text):
                    wanted.add(m.group(1).decode(errors="replace").replace("\\", "/"))

    made = 0
    for name in sorted(wanted):
        if any((inc / name).exists() for inc in args.sdk_include):
            continue
        target = real.get(name.lower())
        if target is None:
            continue
        link = args.out / name
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
        made += 1
    print(f"header_case: {made} case-fixed SDK headers in {args.out}")


if __name__ == "__main__":
    main()
