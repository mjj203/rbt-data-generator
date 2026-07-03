#!/usr/bin/env python3
"""Extract layer names or feature counts from `tippecanoe-decode --stats`.

tippecanoe-decode --stats emits a top-level JSON array with one entry per
tile; each entry's ``layers`` member maps layer name to
``{"points": N, "lines": N, "polygons": N, "extent": E}`` (decode.cpp,
do_stats). Counts here are summed across tiles, so a feature appearing at
several zooms counts once per tile — fine for presence/nonzero assertions,
not a distinct-feature count. A dict top level (mapbox tilestats spec, with
``layers`` as a list or name-keyed dict) is also accepted. Reads JSON on
stdin.

Usage: tippecanoe-decode --stats x.mbtiles | tilestats.py names|counts
"""

import json
import sys


def main() -> None:
    mode = sys.argv[1]
    stats = json.load(sys.stdin)
    counts: dict[str, int] = {}
    if isinstance(stats, list):
        for tile in stats:
            for name, layer in tile.get("layers", {}).items():
                features = sum(layer.get(k, 0) for k in ("points", "lines", "polygons"))
                counts[name] = counts.get(name, 0) + features
    else:
        layers = stats["layers"]
        if isinstance(layers, dict):
            counts = {name: layers[name].get("count", 0) for name in layers}
        else:
            counts = {layer["layer"]: layer.get("count", 0) for layer in layers}
    if mode == "names":
        print(sorted(counts))
    elif mode == "counts":
        print(json.dumps(counts, sort_keys=True))
    else:  # pragma: no cover - argv contract
        raise SystemExit(f"unknown mode: {mode}")


if __name__ == "__main__":
    main()
