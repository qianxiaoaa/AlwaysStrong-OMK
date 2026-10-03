#!/usr/bin/env python3
"""`zip -qr9 <out.zip> <dir>` stand-in for hosts that have no Info-ZIP zip.

build.sh prefers the real zip because it records the Unix permission bits the
installer relies on; stock Windows has neither zip nor an MSYS to borrow one
from. This writes the same archive shape: module root at the archive root, no
directory entries, deflate level 9, and the same mode rules build.sh applies
with chmod before packaging.
"""

import os
import re
import sys
import time
import zipfile

EXEC_PATTERNS = (
    re.compile(r"^[^/]+\.sh$"),
    re.compile(r"^libs/[^/]+/(keymint|inject)$"),
    re.compile(r"^bin/[^/]+/(asfetch|aswatcher)$"),
)
EXEC_EXACT = {"omk-daemon", "omk-injector"}

ZIP_EPOCH = 315532800  # 1980-01-01, the earliest date the format can store


def mode_for(name):
    if name in EXEC_EXACT or any(p.match(name) for p in EXEC_PATTERNS):
        return 0o100755
    return 0o100644


def main(argv):
    if len(argv) != 3:
        sys.exit("usage: zipdir.py <out.zip> <dir>")
    out, root = argv[1], argv[2]
    if not os.path.isdir(root):
        sys.exit(f"not a directory: {root}")

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for base, dirs, files in os.walk(root):
            dirs.sort()
            for name in sorted(files):
                full = os.path.join(base, name)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                info = zipfile.ZipInfo(
                    rel, time.localtime(max(os.stat(full).st_mtime, ZIP_EPOCH))[:6]
                )
                info.external_attr = mode_for(rel) << 16
                info.create_system = 3  # Unix, so the mode above is honoured
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(full, "rb") as fh:
                    z.writestr(info, fh.read())

    print(f"{os.path.getsize(out)} bytes -> {out}")


if __name__ == "__main__":
    main(sys.argv)