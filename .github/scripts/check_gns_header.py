#!/usr/bin/env python3
"""Assert an NGA GNS feature-class zip contains the expected TSV header.

Used by the nightly upstream-probe job: the geonames importer maps the
``lat_dd``/``long_dd`` columns to point geometry, so their disappearance from
the upstream export must fail the probe.

Usage: check_gns_header.py <archive.zip>
"""

import sys
import zipfile


def main() -> None:
    with zipfile.ZipFile(sys.argv[1]) as zf:
        # Skip the disclaimer/guide text files the archives ship alongside the
        # data (mirrors the importer's own member filtering); the data file is
        # by far the largest remaining .txt.
        candidates = [
            info
            for info in zf.infolist()
            if info.filename.endswith(".txt")
            and "disclaimer" not in info.filename.lower()
            and "guide" not in info.filename.lower()
        ]
        assert candidates, f"no data .txt member in archive: {zf.namelist()}"
        data = max(candidates, key=lambda info: info.file_size)
        header = zf.open(data).readline().decode("utf-8", "replace")
    for col in ("lat_dd", "long_dd"):
        assert col in header, f"expected column {col!r} in {header!r} ({data.filename})"
    print(f"GNS header OK ({data.filename}):", header.strip()[:120])


if __name__ == "__main__":
    main()
