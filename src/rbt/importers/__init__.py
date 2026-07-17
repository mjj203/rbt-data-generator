"""Importers for OSM, reference, GeoNames, and Overture datasets.

Each importer is native Python: declarative dataset registries, stdlib
downloads with atomic renames, and thread-pooled ingest jobs. External
geospatial binaries (ogr2ogr, imposm, aria2c, aws, osmium, osmosis) are
invoked as subprocesses via :mod:`rbt.process`; shared plumbing lives in
:mod:`rbt.importers._support`.
"""

from . import buildings, buildings_export, geonames, osm, reference

__all__ = ["buildings", "buildings_export", "geonames", "osm", "reference"]
