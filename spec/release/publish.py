#!/usr/bin/env python3
"""Validate metadata and CI evidence used to publish a LuaRocks release."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ROCKSPEC = ROOT / "mongodb-0.10.2-1.rockspec"
VERSION_PATTERN = re.compile(r"^(?P<version>\d+\.\d+\.\d+)-(?P<revision>\d+)$")
REQUIRED_FULL_JOBS = (
  "linux-quality",
  "linux-unified (0)",
  "linux-unified (1)",
  "linux-unified (2)",
  "linux-unified (3)",
  "linux-version-branches",
  "linux-aggregate",
  "macos-platform",
  "macos-unified (0)",
  "macos-unified (1)",
  "macos-unified (2)",
  "macos-unified (3)",
  "macos-version-branches",
  "macos-aggregate",
  "compatibility (7.0, standalone)",
  "compatibility (7.0, replicaset)",
  "compatibility (7.0, sharded)",
  "compatibility (8.0, standalone)",
  "compatibility (8.0, replicaset)",
  "compatibility (8.0, sharded)",
  "compatibility (8.2, standalone)",
  "compatibility (8.2, replicaset)",
  "compatibility (8.2, sharded)",
)


class PublishError(RuntimeError):
  """Raised when release publication inputs are not reproducible."""


@dataclass(frozen=True)
class ReleaseMetadata:
  package: str
  version: str
  rockspec_version: str
  tag: str
  rockspec: str
  source_rock: str


def _required_match(pattern: str, contents: str, label: str) -> str:
  match = re.search(pattern, contents, re.MULTILINE | re.DOTALL)

  if match is None:
    raise PublishError(f"rockspec does not declare {label}")

  return match.group(1)


def release_metadata(rockspec: Path = DEFAULT_ROCKSPEC) -> ReleaseMetadata:
  try:
    contents = rockspec.read_text(encoding="utf-8")
  except OSError as exc:
    raise PublishError(f"cannot read rockspec {rockspec}: {exc}") from exc

  package = _required_match(r'^package = "([^"]+)"$', contents, "package")
  rockspec_version = _required_match(
    r'^version = "([^"]+)"$', contents, "version"
  )
  source_tag = _required_match(
    r'source\s*=\s*\{.*?\btag\s*=\s*"([^"]+)"',
    contents,
    "source tag",
  )
  version_match = VERSION_PATTERN.fullmatch(rockspec_version)

  if version_match is None:
    raise PublishError(
      f"rockspec version is not a release version: {rockspec_version}"
    )

  version = version_match.group("version")
  expected_tag = f"v{version}"

  if package != "mongodb":
    raise PublishError(f"release package must be mongodb, not {package}")

  if source_tag != expected_tag:
    raise PublishError(
      f"source tag {source_tag} does not match version {version}"
    )

  expected_rockspec = f"{package}-{rockspec_version}.rockspec"

  if rockspec.name != expected_rockspec:
    raise PublishError(
      f"rockspec filename must be {expected_rockspec}, not {rockspec.name}"
    )

  return ReleaseMetadata(
    package=package,
    version=version,
    rockspec_version=rockspec_version,
    tag=source_tag,
    rockspec=rockspec.name,
    source_rock=f"{package}-{rockspec_version}.src.rock",
  )


def require_full_conformance(
  runs: list[dict[str, object]],
  sha: str,
) -> None:
  matching = [
    run for run in runs
    if run.get("headSha") == sha and run.get("conclusion") == "success"
  ]

  if not matching:
    raise PublishError(
      f"no successful Full Conformance run exists for commit {sha}"
    )

  required = set(REQUIRED_FULL_JOBS)

  for run in matching:
    jobs = run.get("jobs")

    if not isinstance(jobs, list):
      continue

    successful = {
      job.get("name")
      for job in jobs
      if isinstance(job, dict) and job.get("conclusion") == "success"
    }

    if required <= successful:
      return

  raise PublishError(
    "successful Full Conformance run does not contain every successful "
    "release job, including macOS"
  )


def _load_runs(path: Path) -> list[dict[str, object]]:
  try:
    value = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise PublishError(f"cannot read conformance runs {path}: {exc}") from exc

  if not isinstance(value, list) or not all(
    isinstance(item, dict) for item in value
  ):
    raise PublishError("conformance runs must be a JSON array of objects")

  return value


def _write_github_output(path: Path, metadata: ReleaseMetadata) -> None:
  values = {
    "package": metadata.package,
    "version": metadata.version,
    "rockspec_version": metadata.rockspec_version,
    "tag": metadata.tag,
    "rockspec": metadata.rockspec,
    "source_rock": metadata.source_rock,
  }

  with path.open("a", encoding="utf-8") as output:
    for name, value in values.items():
      output.write(f"{name}={value}\n")


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  subparsers = parser.add_subparsers(dest="command", required=True)
  metadata = subparsers.add_parser("metadata")
  metadata.add_argument("--rockspec", type=Path, default=DEFAULT_ROCKSPEC)
  metadata.add_argument("--github-output", type=Path)
  conformance = subparsers.add_parser("check-conformance")
  conformance.add_argument("--sha", required=True)
  conformance.add_argument("--runs", required=True, type=Path)
  return parser


def main(argv: Sequence[str] | None = None) -> int:
  args = build_parser().parse_args(argv)

  try:
    if args.command == "metadata":
      metadata = release_metadata(args.rockspec)

      if args.github_output is not None:
        _write_github_output(args.github_output, metadata)
      else:
        print(json.dumps(metadata.__dict__, sort_keys=True))
    elif args.command == "check-conformance":
      require_full_conformance(_load_runs(args.runs), args.sha)
      print(f"full conformance evidence is release-complete for {args.sha}")
  except PublishError as exc:
    print(f"release publication: {exc}", file=sys.stderr)
    return 1

  return 0


if __name__ == "__main__":
  raise SystemExit(main())
