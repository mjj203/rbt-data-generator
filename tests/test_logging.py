"""Tests for ``rbt.logging`` (``configure_logging`` / ``get_logger``)."""

from __future__ import annotations

import logging
from pathlib import Path

from rich.console import Console

from rbt.logging import configure_logging, get_logger


def _reset_root_handlers() -> None:
    root = logging.getLogger()
    for handler in list(root.handlers):
        root.removeHandler(handler)


def test_configure_logging_installs_a_single_rich_handler() -> None:
    _reset_root_handlers()
    try:
        configure_logging(level="INFO")
        root = logging.getLogger()
        assert len(root.handlers) == 1
        assert root.level == logging.INFO
    finally:
        _reset_root_handlers()


def test_configure_logging_replaces_rather_than_stacks_handlers() -> None:
    """Calling configure_logging() twice must not duplicate handlers (each CLI
    invocation calls it exactly once, but the guarantee matters for tests and
    any future multi-invocation-in-process use)."""
    _reset_root_handlers()
    try:
        configure_logging(level="INFO")
        configure_logging(level="DEBUG")
        root = logging.getLogger()
        assert len(root.handlers) == 1
        assert root.level == logging.DEBUG
    finally:
        _reset_root_handlers()


def test_configure_logging_unknown_level_falls_back_to_info() -> None:
    _reset_root_handlers()
    try:
        configure_logging(level="NOT-A-LEVEL")
        assert logging.getLogger().level == logging.INFO
    finally:
        _reset_root_handlers()


def test_configure_logging_adds_file_handler_when_requested(tmp_path: Path) -> None:
    log_file = tmp_path / "nested" / "rbt.log"
    _reset_root_handlers()
    try:
        configure_logging(level="INFO", log_file=log_file, console=Console(stderr=True))
        root = logging.getLogger()
        assert len(root.handlers) == 2
        assert any(isinstance(h, logging.FileHandler) for h in root.handlers)
        # delay=True: the file is only created lazily, on first emitted record.
        logging.getLogger("rbt").info("hello")
        assert log_file.exists()
    finally:
        _reset_root_handlers()


def test_configure_logging_without_file_adds_no_file_handler() -> None:
    _reset_root_handlers()
    try:
        configure_logging(level="INFO", log_file=None)
        root = logging.getLogger()
        assert not any(isinstance(h, logging.FileHandler) for h in root.handlers)
    finally:
        _reset_root_handlers()


def test_get_logger_default_name_is_rbt() -> None:
    logger = get_logger()
    assert logger.name == "rbt"


def test_get_logger_custom_name() -> None:
    logger = get_logger("rbt.cli")
    assert logger.name == "rbt.cli"


def test_configure_logging_returns_rbt_logger() -> None:
    _reset_root_handlers()
    try:
        result = configure_logging(level="INFO")
        assert result.name == "rbt"
    finally:
        _reset_root_handlers()
