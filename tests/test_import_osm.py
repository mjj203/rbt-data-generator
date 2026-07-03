"""Tests for the native OSM import stages (``rbt.importers.osm``)."""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from rbt.config import load_settings
from rbt.importers import _support
from rbt.importers import osm as osm_mod
from rbt.importers._support import ImportFailed
from rbt.importers.osm import OsmStage
from rbt.process import CommandFailed

MB = 1024 * 1024

USER_AGENT = "OpenMapTiles download-osm 7.1.1 (https://github.com/openmaptiles/openmaptiles-tools)"

# Golden copy of the bash script's mirror list, in order.
EXPECTED_MIRRORS = [
    "https://ftp.spline.de/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://ftp5.gwdg.de/pub/misc/openstreetmap/planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
    "https://ftp.fau.de/osm-planet/pbf/planet-latest.osm.pbf",
    "https://ftpmirror.your.org/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://download.bbbike.org/osm/planet/planet-latest.osm.pbf",
    "https://ftp.nluug.nl/maps/planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
    "https://ftp.osuosl.org/pub/openstreetmap/pbf/planet-latest.osm.pbf",
    "https://ftp.snt.utwente.nl/pub/misc/openstreetmap/planet-latest.osm.pbf",
    "https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf",
]


@pytest.fixture
def osm_dirs(fake_repo: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point the OSM data/cache/diff dirs at the fake repo; returns data dir."""
    root = fake_repo.resolve()
    data = root / "osm-data"
    cache = root / "osm-cache"
    diff = root / "osm-diff"
    for directory in (data, cache, diff):
        directory.mkdir()
    monkeypatch.setenv("OSM_DATA_DIR", str(data))
    monkeypatch.setenv("OSM_CACHE_DIR", str(cache))
    monkeypatch.setenv("OSM_DIFF_DIR", str(diff))
    return data


def _sparse_file(path: Path, size_mb: int) -> None:
    """Create a file whose st_size is *size_mb* MB without writing the bytes."""
    with path.open("wb") as handle:
        handle.truncate(size_mb * MB)


def _stage_stub(order: list[str], name: str):
    def stub(settings, *args, **kwargs):
        order.append(name)

    return stub


# ---------------------------------------------------------------------------
# download_planet
# ---------------------------------------------------------------------------


def test_download_planet_argv_golden(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("ARIA2C_MAX_DOWNLOADS", "5")
    monkeypatch.setenv("ARIA2C_MAX_CONNECTIONS", "7")
    monkeypatch.setenv("ARIA2C_SPLITS", "3")
    monkeypatch.setenv("OSM_VALIDATE_DOWNLOADS", "false")
    settings = load_settings()

    osm_mod.download_planet(settings)

    [call] = recorded_run.calls
    assert call["cmd"] == [
        "aria2c",
        "--file-allocation=falloc",
        "--max-concurrent-downloads=5",
        "--max-connection-per-server=7",
        "--split=3",
        "--http-accept-gzip=true",
        f"--user-agent={USER_AGENT}",
        f"--dir={osm_dirs}",
        "--out=planet-latest-v2.osm.pbf",
        "--auto-file-renaming=false",
        "--continue=true",
        "--max-tries=3",
        "--retry-wait=10",
        "--timeout=300",
        "--summary-interval=60",
        *EXPECTED_MIRRORS,
    ]
    assert call["retries"] == settings.retry_count
    assert call["delay"] == settings.retry_delay
    assert call["dry_run"] is False


def test_download_planet_skips_existing_valid_file(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_MIN_PBF_SIZE_MB", "1")
    (osm_dirs / "planet-latest-v2.osm.pbf").write_bytes(b"0" * (MB + 1))

    osm_mod.download_planet(load_settings())

    assert recorded_run.calls == []


def test_download_planet_validation_failure_raises(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_MIN_PBF_SIZE_MB", "1")
    monkeypatch.setenv("OSM_VALIDATE_DOWNLOADS", "true")
    settings = load_settings()

    # The recorded aria2c "succeeds" but leaves no file behind.
    with pytest.raises(ImportFailed):
        osm_mod.download_planet(settings)
    assert len(recorded_run.calls) == 1


# ---------------------------------------------------------------------------
# download_diffs
# ---------------------------------------------------------------------------


def test_download_diffs_url_layout_and_zero_padding(osm_dirs, monkeypatch):
    seen: list[tuple[str, Path, int]] = []

    def fake_download(url, dest, *, min_bytes=1, **kwargs):
        seen.append((url, dest, min_bytes))
        return dest

    monkeypatch.setattr(_support, "download", fake_download)

    osm_mod.download_diffs(load_settings(), 7, 9)

    base = "https://planet.openstreetmap.org/replication/day/000/004"
    assert sorted(seen) == [
        (f"{base}/007.osc.gz", osm_dirs / "007.osc.gz", MB),
        (f"{base}/008.osc.gz", osm_dirs / "008.osc.gz", MB),
        (f"{base}/009.osc.gz", osm_dirs / "009.osc.gz", MB),
    ]


@pytest.mark.parametrize(("start", "end"), [(9, 7), (-1, 5), (3, -2)])
def test_download_diffs_invalid_sequence_range(osm_dirs, monkeypatch, start, end):
    def boom(*args, **kwargs):
        raise AssertionError("download must not be attempted for an invalid range")

    monkeypatch.setattr(_support, "download", boom)

    with pytest.raises(ValueError, match="SEQ|non-negative"):
        osm_mod.download_diffs(load_settings(), start, end)


def test_download_diffs_pool_failure_raises_import_failed(osm_dirs, monkeypatch):
    def fake_download(url, dest, **kwargs):
        if url.endswith("008.osc.gz"):
            raise OSError("boom")
        dest.write_bytes(b"x")
        return dest

    monkeypatch.setattr(_support, "download", fake_download)
    # run_jobs sleeps settings.retry_delay between attempts; _support's `time`
    # is the stdlib module, so patching time.sleep silences that wait.
    monkeypatch.setattr(time, "sleep", lambda seconds: None)

    with pytest.raises(ImportFailed) as excinfo:
        osm_mod.download_diffs(load_settings(), 7, 9)
    assert excinfo.value.failed == ["008.osc.gz"]


def test_download_diffs_skips_existing_files_over_one_mb(osm_dirs):
    for seq in (7, 8):
        (osm_dirs / f"{seq:03d}.osc.gz").write_bytes(b"0" * (MB + 1))

    # Uses the real _support.download: files >= 1 MB short-circuit before any
    # network access, so this completing at all proves the skip path.
    osm_mod.download_diffs(load_settings(), 7, 8)


def test_download_diffs_defaults_come_from_settings(osm_dirs, monkeypatch):
    monkeypatch.setenv("DIFF_START_SEQ", "5")
    monkeypatch.setenv("DIFF_END_SEQ", "6")
    seen: list[str] = []

    def fake_download(url, dest, **kwargs):
        seen.append(url)
        return dest

    monkeypatch.setattr(_support, "download", fake_download)

    osm_mod.download_diffs(load_settings())

    assert sorted(seen) == [
        "https://planet.openstreetmap.org/replication/day/000/004/005.osc.gz",
        "https://planet.openstreetmap.org/replication/day/000/004/006.osc.gz",
    ]


# ---------------------------------------------------------------------------
# merge_diffs
# ---------------------------------------------------------------------------


def test_merge_diffs_argv_numerically_sorted_with_cwd(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_VALIDATE_DOWNLOADS", "false")
    for name in ("999.osc.gz", "007.osc.gz", "1000.osc.gz"):
        (osm_dirs / name).write_bytes(b"x")
    # The merged output must never be treated as an input.
    (osm_dirs / "osm.osc.gz").write_bytes(b"x")
    settings = load_settings()

    osm_mod.merge_diffs(settings)

    [call] = recorded_run.calls
    assert call["cmd"] == [
        "osmium",
        "merge-changes",
        "-o",
        "osm.osc.gz",
        "-s",
        "007.osc.gz",
        "999.osc.gz",
        "1000.osc.gz",
    ]
    assert call["cwd"] == settings.osm_data_dir == osm_dirs


def test_merge_diffs_without_diff_files_raises(osm_dirs, recorded_run):
    with pytest.raises(FileNotFoundError):
        osm_mod.merge_diffs(load_settings())
    assert recorded_run.calls == []


def test_merge_diffs_validation_failure_raises(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_VALIDATE_DOWNLOADS", "true")
    (osm_dirs / "007.osc.gz").write_bytes(b"x")

    # Recorded osmium produces no osm.osc.gz, so the >= 10 MB check fails.
    with pytest.raises(ImportFailed):
        osm_mod.merge_diffs(load_settings())


# ---------------------------------------------------------------------------
# apply_changes
# ---------------------------------------------------------------------------


def test_apply_changes_argv_golden(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_VALIDATE_DOWNLOADS", "false")
    _sparse_file(osm_dirs / "osm.osc.gz", 10)
    _sparse_file(osm_dirs / "planet-latest-v2.osm.pbf", 50_000)
    settings = load_settings()

    osm_mod.apply_changes(settings)

    [call] = recorded_run.calls
    assert call["cmd"] == [
        "osmosis",
        "--read-xml-change",
        "file=osm.osc.gz",
        "--read-pbf",
        "file=planet-latest-v2.osm.pbf",
        "--apply-change",
        "--write-pbf",
        "file=planet.osm.pbf",
    ]
    assert call["cwd"] == settings.osm_data_dir


def test_apply_changes_missing_inputs_raise(osm_dirs, recorded_run):
    with pytest.raises(FileNotFoundError):
        osm_mod.apply_changes(load_settings())
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# import_planet
# ---------------------------------------------------------------------------


def test_import_planet_argv_golden_with_password(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_MIN_PBF_SIZE_MB", "1")
    monkeypatch.setenv("PG_PASS", "s3cret")
    (osm_dirs / "planet.osm.pbf").write_bytes(b"0" * (MB + 1))
    settings = load_settings()

    osm_mod.import_planet(settings)

    [call] = recorded_run.calls
    root = settings.project_root
    # imposm needs the password in the URL (it does not read PGPASSWORD);
    # log redaction of the userinfo is covered by the process-module tests.
    connection = "postgis://postgres:s3cret@localhost:5432/rbt?prefix=NONE"
    assert call["cmd"] == [
        "imposm",
        "import",
        "-config",
        str(root / "setup/data-sources/osm/imposm-config.json"),
        "-mapping",
        str(root / "setup/data-sources/osm/imposm-mapping.yaml"),
        "-cachedir",
        str(root / "osm-cache"),
        "-diffdir",
        str(root / "osm-diff"),
        "-srid",
        "4326",
        "-connection",
        connection,
        "-read",
        str(osm_dirs / "planet.osm.pbf"),
        "-write",
        "-diff",
        "-optimize",
    ]
    log_file = call["log_file"]
    assert isinstance(log_file, Path)
    assert log_file.parent == settings.shared_log_dir
    assert log_file.name.startswith("osm_import_")


def test_import_planet_missing_planet_raises(osm_dirs, monkeypatch, recorded_run):
    monkeypatch.setenv("OSM_MIN_PBF_SIZE_MB", "1")
    with pytest.raises(FileNotFoundError):
        osm_mod.import_planet(load_settings())
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# import_diffs
# ---------------------------------------------------------------------------


def test_import_diffs_sorted_paths_and_size_filter(osm_dirs, recorded_run):
    (osm_dirs / "010.osc.gz").write_bytes(b"0" * (MB + 1))
    (osm_dirs / "002.osc.gz").write_bytes(b"0" * (MB + 1))
    (osm_dirs / "003.osc.gz").write_bytes(b"tiny")  # < 1 MB: skipped with a warning
    settings = load_settings()

    osm_mod.import_diffs(settings)

    [call] = recorded_run.calls
    root = settings.project_root
    assert call["cmd"] == [
        "imposm",
        "diff",
        "-config",
        str(root / "setup/data-sources/osm/imposm-config.json"),
        "-connection",
        settings.imposm_connection(),
        "-diffdir",
        str(root / "osm-diff"),
        "-srid",
        "4326",
        "-mapping",
        str(root / "setup/data-sources/osm/imposm-mapping.yaml"),
        "-cachedir",
        str(root / "osm-cache"),
        str(osm_dirs / "002.osc.gz"),
        str(osm_dirs / "010.osc.gz"),
    ]


def test_import_diffs_none_found_raises(osm_dirs, recorded_run):
    with pytest.raises(FileNotFoundError):
        osm_mod.import_diffs(load_settings())
    assert recorded_run.calls == []


# ---------------------------------------------------------------------------
# run_import orchestration
# ---------------------------------------------------------------------------


def test_run_import_all_dry_run_sequences_stages(osm_dirs, recorded_run):
    osm_mod.run_import(load_settings(), OsmStage.all, dry_run=True)

    # download_diffs streams through _support.download, not process.run, so the
    # recorded external commands are the other four stages in pipeline order.
    assert [cmd[0] for cmd in recorded_run.commands] == ["aria2c", "osmium", "osmosis", "imposm"]
    assert recorded_run.commands[-1][1] == "import"
    assert all(call["dry_run"] is True for call in recorded_run.calls)
    # The bash --all ended with `imposm run`; the native pipeline must not.
    assert not any(cmd[:2] == ["imposm", "run"] for cmd in recorded_run.commands)


def test_run_import_all_cleanup_removes_intermediates_only(osm_dirs, monkeypatch):
    monkeypatch.setenv("OSM_CLEANUP_ON_EXIT", "true")
    order: list[str] = []
    for name in (
        "download_planet",
        "download_diffs",
        "merge_diffs",
        "apply_changes",
        "import_planet",
    ):
        monkeypatch.setattr(osm_mod, name, _stage_stub(order, name))
    merged = osm_dirs / "osm.osc.gz"
    updated = osm_dirs / "planet.osm.pbf"
    planet = osm_dirs / "planet-latest-v2.osm.pbf"
    diff = osm_dirs / "007.osc.gz"
    for path in (merged, updated, planet, diff):
        path.write_bytes(b"x")

    osm_mod.run_import(load_settings(), OsmStage.all)

    assert order == [
        "download_planet",
        "download_diffs",
        "merge_diffs",
        "apply_changes",
        "import_planet",
    ]
    assert not merged.exists()
    assert not updated.exists()
    # Only the intermediates go; the planet download and diffs stay.
    assert planet.exists()
    assert diff.exists()


def test_run_import_all_cleanup_disabled_keeps_files(osm_dirs, monkeypatch):
    monkeypatch.setenv("OSM_CLEANUP_ON_EXIT", "false")
    for name in (
        "download_planet",
        "download_diffs",
        "merge_diffs",
        "apply_changes",
        "import_planet",
    ):
        monkeypatch.setattr(osm_mod, name, _stage_stub([], name))
    merged = osm_dirs / "osm.osc.gz"
    updated = osm_dirs / "planet.osm.pbf"
    for path in (merged, updated):
        path.write_bytes(b"x")

    osm_mod.run_import(load_settings(), OsmStage.all)

    assert merged.exists()
    assert updated.exists()


def test_run_import_single_stage_never_cleans_up(osm_dirs, monkeypatch):
    monkeypatch.setenv("OSM_CLEANUP_ON_EXIT", "true")
    monkeypatch.setattr(osm_mod, "merge_diffs", _stage_stub([], "merge_diffs"))
    merged = osm_dirs / "osm.osc.gz"
    updated = osm_dirs / "planet.osm.pbf"
    for path in (merged, updated):
        path.write_bytes(b"x")

    osm_mod.run_import(load_settings(), OsmStage.merge_diffs)

    assert merged.exists()
    assert updated.exists()


def test_run_import_all_failed_stage_skips_cleanup(osm_dirs, monkeypatch):
    monkeypatch.setenv("OSM_CLEANUP_ON_EXIT", "true")
    for name in ("download_planet", "download_diffs", "merge_diffs", "apply_changes"):
        monkeypatch.setattr(osm_mod, name, _stage_stub([], name))

    def boom(settings, *, dry_run=False):
        raise CommandFailed(["imposm", "import"], 1)

    monkeypatch.setattr(osm_mod, "import_planet", boom)
    merged = osm_dirs / "osm.osc.gz"
    updated = osm_dirs / "planet.osm.pbf"
    for path in (merged, updated):
        path.write_bytes(b"x")

    with pytest.raises(CommandFailed):
        osm_mod.run_import(load_settings(), OsmStage.all)

    assert merged.exists()
    assert updated.exists()


# ---------------------------------------------------------------------------
# dry-run: no filesystem preconditions enforced
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("stage", "binary"),
    [
        (OsmStage.download_planet, "aria2c"),
        (OsmStage.merge_diffs, "osmium"),
        (OsmStage.apply_changes, "osmosis"),
        (OsmStage.import_, "imposm"),
        (OsmStage.import_diff, "imposm"),
    ],
)
def test_stage_dry_run_skips_preconditions(osm_dirs, recorded_run, stage, binary):
    # Empty data dir: every non-dry-run precondition would fail here.
    osm_mod.run_import(load_settings(), stage, dry_run=True)

    [call] = recorded_run.calls
    assert call["cmd"][0] == binary
    assert call["dry_run"] is True


def test_download_diffs_dry_run_has_no_side_effects(osm_dirs, recorded_run):
    osm_mod.download_diffs(load_settings(), 7, 8, dry_run=True)

    assert recorded_run.calls == []
    assert list(osm_dirs.iterdir()) == []


# ---------------------------------------------------------------------------
# back-compat alias and string stages
# ---------------------------------------------------------------------------


def test_import_osm_alias_and_string_stage_dispatch(osm_dirs, recorded_run):
    settings = load_settings()

    osm_mod.import_osm(settings, stage=OsmStage.merge_diffs, dry_run=True)
    osm_mod.run_import(settings, "merge-diffs", dry_run=True)

    assert [cmd[0] for cmd in recorded_run.commands] == ["osmium", "osmium"]
    assert all(call["dry_run"] is True for call in recorded_run.calls)
