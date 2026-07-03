#!/usr/bin/env python3
"""Extract layer names or feature counts from `tippecanoe-decode --stats`.

The tilestats JSON's ``layers`` member is a list of per-layer objects (mapbox
tilestats spec), but older/alternate emitters use a name-keyed dict — accept
both. Reads JSON on stdin.

Usage: tippecanoe-decode --stats x.mbtiles | tilestats.py names|counts
"""

import json
import sys


def main() -> None:
    mode = sys.argv[1]
    stats = json.load(sys.stdin)
    layers = stats["layers"]
    if isinstance(layers, dict):
        names = sorted(layers)
        counts = {name: layers[name].get("count", 0) for name in names}
    else:
        names = sorted(layer["layer"] for layer in layers)
        counts = {layer["layer"]: layer.get("count", 0) for layer in layers}
    if mode == "names":
        print(names)
    elif mode == "counts":
        print(json.dumps(counts, sort_keys=True))
    else:  # pragma: no cover - argv contract
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
