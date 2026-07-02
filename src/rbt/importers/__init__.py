"""Importers for OSM, reference, GeoNames, and Overture datasets.

Current implementation shells out to the existing Bash scripts, which
remain the source of truth for the complex parallel-download orchestration.
The Python wrapper adds structured logging, typed error handling, and CLI
ergonomics; rewriting the download loops in pure Python is a future step.
"""

from . import buildings, geonames, osm, reference

__all__ = ["buildings", "geonames", "osm", "reference"]
