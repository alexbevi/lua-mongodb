#!/usr/bin/env python3
"""Build an upload-safe source rock from an immutable Git tree."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Sequence
import zipfile


DEFAULT_MAX_BYTES = 10 * 1024 * 1024
SOURCE_DIRECTORY_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")


class SourceRockError(RuntimeError):
  """Raised when an immutable source rock cannot be constructed safely."""


def _run_git(repository: Path, arguments: list[str]) -> subprocess.CompletedProcess:
  try:
    return subprocess.run(
      ["git", "-C", str(repository), *arguments],
      check=False,
      capture_output=True,
    )
  except OSError as exc:
    raise SourceRockError(f"cannot execute git: {exc}") from exc


def _git_output(repository: Path, arguments: list[str], label: str) -> bytes:
  result = _run_git(repository, arguments)

  if result.returncode != 0:
    message = result.stderr.decode("utf-8", errors="replace").strip()
    raise SourceRockError(f"cannot {label}: {message}")

  return result.stdout


def _relative_rockspec(repository: Path, rockspec: Path) -> Path:
  try:
    return rockspec.resolve().relative_to(repository.resolve())
  except ValueError as exc:
    raise SourceRockError("rockspec must be inside the release repository") from exc


def _append_root_rockspec(archive: Path, rockspec: Path) -> None:
  info = zipfile.ZipInfo(rockspec.name, date_time=(1980, 1, 1, 0, 0, 0))
  info.compress_type = zipfile.ZIP_DEFLATED
  info.create_system = 3
  info.external_attr = 0o100644 << 16

  try:
    with zipfile.ZipFile(archive, mode="a") as source_rock:
      source_rock.writestr(info, rockspec.read_bytes())
  except (OSError, zipfile.BadZipFile) as exc:
    raise SourceRockError(f"cannot finalize source rock: {exc}") from exc


def build_source_rock(
  repository: Path,
  commit: str,
  rockspec: Path,
  source_directory: str,
  output: Path,
  max_bytes: int = DEFAULT_MAX_BYTES,
) -> None:
  if not SOURCE_DIRECTORY_PATTERN.fullmatch(source_directory):
    raise SourceRockError("source directory must be one safe path component")

  if max_bytes <= 0:
    raise SourceRockError("maximum artifact size must be positive")

  relative_rockspec = _relative_rockspec(repository, rockspec)
  canonical_commit = _git_output(
    repository,
    ["rev-parse", f"{commit}^{{commit}}"],
    f"resolve commit {commit}",
  ).decode("ascii").strip()
  committed_rockspec = _git_output(
    repository,
    ["show", f"{canonical_commit}:{relative_rockspec.as_posix()}"],
    "read the committed rockspec",
  )

  try:
    local_rockspec = rockspec.read_bytes()
  except OSError as exc:
    raise SourceRockError(f"cannot read rockspec {rockspec}: {exc}") from exc

  if local_rockspec != committed_rockspec:
    raise SourceRockError("rockspec does not match the immutable release tree")

  output.parent.mkdir(parents=True, exist_ok=True)
  temporary = tempfile.NamedTemporaryFile(
    dir=output.parent,
    prefix=f".{output.name}.",
    suffix=".tmp",
    delete=False,
  )
  temporary_path = Path(temporary.name)
  temporary.close()

  try:
    archived = _run_git(
      repository,
      [
        "archive",
        "--format=zip",
        f"--prefix={source_directory}/",
        f"--output={temporary_path}",
        canonical_commit,
      ],
    )

    if archived.returncode != 0:
      message = archived.stderr.decode("utf-8", errors="replace").strip()
      raise SourceRockError(f"cannot archive release tree: {message}")

    _append_root_rockspec(temporary_path, rockspec)
    artifact_size = temporary_path.stat().st_size

    if artifact_size > max_bytes:
      raise SourceRockError(
        f"source rock is {artifact_size} bytes; maximum is {max_bytes}"
      )

    temporary_path.chmod(0o644)
    os.replace(temporary_path, output)
  finally:
    temporary_path.unlink(missing_ok=True)


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--repository", required=True, type=Path)
  parser.add_argument("--commit", required=True)
  parser.add_argument("--rockspec", required=True, type=Path)
  parser.add_argument("--source-directory", required=True)
  parser.add_argument("--output", required=True, type=Path)
  parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  args = build_parser().parse_args(argv)

  try:
    build_source_rock(
      repository=args.repository,
      commit=args.commit,
      rockspec=args.rockspec,
      source_directory=args.source_directory,
      output=args.output,
      max_bytes=args.max_bytes,
    )
  except SourceRockError as exc:
    print(f"source-rock build: {exc}", file=sys.stderr)
    return 1

  print(f"Packed: {args.output}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
