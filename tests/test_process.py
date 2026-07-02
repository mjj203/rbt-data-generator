"""Tests for the subprocess helpers (``rbt.process``)."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

import rbt.process
from rbt.process import CommandFailed, run, run_with_retry


def test_dry_run_returns_zero_and_executes_nothing(tmp_path: Path) -> None:
    target = tmp_path / "should-not-exist"
    result = run(["touch", str(target)], dry_run=True)
    assert result.returncode == 0
    assert not target.exists()


def test_command_failed_message_contains_argv_and_stderr() -> None:
    cmd = ["sh", "-c", "echo boom >&2; exit 7"]
    with pytest.raises(CommandFailed) as excinfo:
        run(cmd, capture_output=True)
    message = str(excinfo.value)
    assert "exit 7" in message
    assert "sh -c" in message
    assert "boom" in message
    assert excinfo.value.cmd == cmd
    assert excinfo.value.returncode == 7


def test_check_false_passes_through_nonzero_returncode() -> None:
    result = run(["false"], check=False)
    assert result.returncode != 0


def test_password_is_redacted_in_log_file(tmp_path: Path) -> None:
    log_file = tmp_path / "run.log"
    # `true` ignores its args and prints nothing, so the only place the secret
    # could appear is the command header that process.run writes.
    run(["true", "PG:dbname=rbt password=s3cr3t user=rbt"], log_file=log_file)
    content = log_file.read_text(encoding="utf-8")
    assert "password=***" in content
    assert "s3cr3t" not in content


def test_password_is_redacted_in_command_failed_message() -> None:
    cmd = ["sh", "-c", "exit 3", "password=s3cr3t"]
    with pytest.raises(CommandFailed) as excinfo:
        run(cmd)
    message = str(excinfo.value)
    assert "password=***" in message
    assert "s3cr3t" not in message


def test_log_file_tee_creates_parents_and_writes_header(tmp_path: Path) -> None:
    log_file = tmp_path / "nested" / "dir" / "run.log"
    run(["echo", "hello-tee"], log_file=log_file)
    assert log_file.parent.is_dir()
    content = log_file.read_text(encoding="utf-8")
    assert "--- $ echo hello-tee" in content
    assert "hello-tee\n" in content


def test_log_file_appends_instead_of_truncating(tmp_path: Path) -> None:
    log_file = tmp_path / "run.log"
    run(["echo", "first"], log_file=log_file)
    run(["echo", "second"], log_file=log_file)
    content = log_file.read_text(encoding="utf-8")
    assert content.count("--- $") == 2
    assert "first" in content
    assert "second" in content


def test_log_file_failure_still_raises_and_logs_header(tmp_path: Path) -> None:
    log_file = tmp_path / "logs" / "fail.log"
    with pytest.raises(CommandFailed):
        run(["false"], log_file=log_file)
    assert "--- $ false" in log_file.read_text(encoding="utf-8")


def test_run_with_retry_exhausts_attempts_and_raises(monkeypatch) -> None:
    sleeps: list[float] = []
    monkeypatch.setattr(rbt.process, "time", SimpleNamespace(sleep=sleeps.append))
    with pytest.raises(CommandFailed):
        run_with_retry(["false"], retries=3, delay=1.5)
    # Sleeps between attempts only: 3 attempts -> 2 sleeps.
    assert sleeps == [1.5, 1.5]


def test_run_with_retry_succeeds_on_later_attempt(tmp_path: Path, monkeypatch) -> None:
    sleeps: list[float] = []
    monkeypatch.setattr(rbt.process, "time", SimpleNamespace(sleep=sleeps.append))
    flag = tmp_path / "flag"
    cmd = ["sh", "-c", f'if [ -e "{flag}" ]; then exit 0; else touch "{flag}"; exit 1; fi']
    result = run_with_retry(cmd, retries=3, delay=2.5)
    assert result.returncode == 0
    assert sleeps == [2.5]
