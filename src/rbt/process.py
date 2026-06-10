"""Subprocess helpers with logging and retry."""

from __future__ import annotations

import os
import shlex
import subprocess
import time
from collections.abc import Mapping, Sequence
from pathlib import Path

from .logging import get_logger

log = get_logger(__name__)


class CommandFailed(RuntimeError):
    def __init__(self, cmd: Sequence[str], returncode: int, stderr: str = "") -> None:
        self.cmd = list(cmd)
        self.returncode = returncode
        self.stderr = stderr
        super().__init__(
            f"Command failed (exit {returncode}): {shlex.join(self.cmd)}"
            + (f"\n{stderr.strip()}" if stderr else "")
        )


def run(
    cmd: Sequence[str],
    *,
    cwd: Path | str | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    capture_output: bool = False,
    log_file: Path | None = None,
    dry_run: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run *cmd*, optionally tee'ing output to *log_file*."""
    rendered = shlex.join(cmd)

    if dry_run:
        log.info("[dry-run] %s", rendered)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    log.info("$ %s", rendered)

    merged_env: dict[str, str] | None = None
    if env is not None:
        merged_env = {**os.environ, **env}

    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        with log_file.open("ab") as handle:
            handle.write(f"\n--- $ {rendered}\n".encode())
            handle.flush()
            teed = subprocess.run(  # noqa: S603 - caller-supplied commands
                cmd,
                cwd=str(cwd) if cwd is not None else None,
                env=merged_env,
                stdout=handle,
                stderr=subprocess.STDOUT,
                check=False,
            )
        if check and teed.returncode != 0:
            raise CommandFailed(cmd, teed.returncode)
        return subprocess.CompletedProcess(cmd, teed.returncode, "", "")

    completed: subprocess.CompletedProcess[str] = subprocess.run(  # noqa: S603
        cmd,
        cwd=str(cwd) if cwd is not None else None,
        env=merged_env,
        text=True,
        capture_output=capture_output,
        check=False,
    )
    if check and completed.returncode != 0:
        raise CommandFailed(cmd, completed.returncode, completed.stderr or "")
    return completed


def run_with_retry(
    cmd: Sequence[str],
    *,
    retries: int = 3,
    delay: float = 10.0,
    **kwargs: object,
) -> subprocess.CompletedProcess[str]:
    last_error: CommandFailed | None = None
    for attempt in range(1, retries + 1):
        try:
            return run(cmd, **kwargs)  # type: ignore[arg-type]
        except CommandFailed as exc:
            last_error = exc
            if attempt < retries:
                log.warning(
                    "attempt %d/%d failed (exit %d); retrying in %.0fs",
                    attempt,
                    retries,
                    exc.returncode,
                    delay,
                )
                time.sleep(delay)
            else:
                raise
    assert last_error is not None
    raise last_error
