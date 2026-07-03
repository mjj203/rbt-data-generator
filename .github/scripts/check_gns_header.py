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
        txt = [n for n in zf.namelist() if n.endswith(".txt")]
        assert txt, f"no .txt member in archive: {zf.namelist()}"
        header = zf.open(txt[0]).readline().decode("utf-8", "replace")
    for col in ("lat_dd", "long_dd"):
        assert col in header, f"expected column {col!r} in {header!r}"
    print("GNS header OK:", header.strip()[:120])


if __name__ == "__main__":
    main()
