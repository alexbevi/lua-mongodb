#!/usr/bin/env python3
"""Check LuaCov line coverage against a per-file ratchet baseline."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any


SCHEMA_VERSION = 1
SOURCE_ROW = re.compile(
  r"^(?P<file>src/mongodb/\S+\.lua)\s+"
  r"(?P<hits>\d+)\s+(?P<missed>\d+)\s+\d+(?:\.\d+)?%$"
)
TOTAL_ROW = re.compile(
  r"^Total\s+(?P<hits>\d+)\s+(?P<missed>\d+)\s+\d+(?:\.\d+)?%$"
)


class CoverageError(ValueError):
  """Raised when coverage input is missing or malformed."""


def _metric(hits: str, missed: str) -> dict[str, int]:
  covered = int(hits)
  active = covered + int(missed)

  if active <= 0:
    raise CoverageError("coverage metrics must contain at least one active line")

  return {"covered": covered, "active": active}


def parse_report(path: Path) -> dict[str, Any]:
  """Parse the machine-stable summary table in a LuaCov text report."""
  files: dict[str, dict[str, int]] = {}
  reported_total = None

  try:
    lines = path.read_text(encoding="utf-8").splitlines()
  except OSError as exc:
    raise CoverageError(f"cannot read coverage report {path}: {exc}") from exc

  for line in lines:
    source_match = SOURCE_ROW.match(line)

    if source_match:
      filename = source_match.group("file")
      files[filename] = _metric(
        source_match.group("hits"), source_match.group("missed")
      )
      continue

    total_match = TOTAL_ROW.match(line)

    if total_match:
      reported_total = _metric(
        total_match.group("hits"), total_match.group("missed")
      )

  if not files:
    raise CoverageError("coverage report contains no src/mongodb Lua files")

  total = {
    "covered": sum(metric["covered"] for metric in files.values()),
    "active": sum(metric["active"] for metric in files.values()),
  }

  if reported_total != total:
    raise CoverageError(
      f"coverage report total {reported_total!r} does not match source rows {total!r}"
    )

  return {
    "schema_version": SCHEMA_VERSION,
    "files": dict(sorted(files.items())),
    "total": total,
  }


def load_baseline(path: Path) -> dict[str, Any]:
  try:
    baseline = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CoverageError(f"cannot read coverage baseline {path}: {exc}") from exc

  if baseline.get("schema_version") != SCHEMA_VERSION:
    raise CoverageError("unsupported coverage baseline schema version")

  if not isinstance(baseline.get("files"), dict):
    raise CoverageError("coverage baseline files must be an object")

  return baseline


def _is_lower(measured: dict[str, int], baseline: dict[str, int]) -> bool:
  return (
    measured["covered"] * baseline["active"]
    < baseline["covered"] * measured["active"]
  )


def regressions(
  measured: dict[str, Any], baseline: dict[str, Any]
) -> list[str]:
  """Return deterministic diagnostics for every coverage regression."""
  violations = []
  measured_files = measured["files"]
  baseline_files = baseline["files"]

  for filename in sorted(set(baseline_files) | set(measured_files)):
    current = measured_files.get(filename)
    expected = baseline_files.get(filename)

    if current is None:
      violations.append(f"{filename}: source file is missing from the coverage report")
    elif expected is None:
      violations.append(f"{filename}: source file has no checked-in coverage baseline")
    elif _is_lower(current, expected):
      violations.append(
        f"{filename}: line coverage regressed from "
        f"{expected['covered']}/{expected['active']} to "
        f"{current['covered']}/{current['active']}"
      )

  if _is_lower(measured["total"], baseline["total"]):
    expected = baseline["total"]
    current = measured["total"]
    violations.append(
      "total: line coverage regressed from "
      f"{expected['covered']}/{expected['active']} to "
      f"{current['covered']}/{current['active']}"
    )

  return violations


def _percentage(metric: dict[str, int]) -> float:
  return metric["covered"] / metric["active"] * 100


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--report", type=Path, required=True)
  parser.add_argument("--baseline", type=Path, required=True)
  parser.add_argument("--write-baseline", action="store_true")
  args = parser.parse_args(argv)

  try:
    measured = parse_report(args.report)

    if args.write_baseline:
      args.baseline.write_text(
        json.dumps(measured, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
      )
      print(
        f"wrote coverage baseline: {measured['total']['covered']}/"
        f"{measured['total']['active']} lines "
        f"({_percentage(measured['total']):.2f}%)"
      )
      return 0

    baseline = load_baseline(args.baseline)
    violations = regressions(measured, baseline)
  except CoverageError as exc:
    print(f"coverage gate: {exc}", file=sys.stderr)
    return 2

  if violations:
    for violation in violations:
      print(f"coverage gate: {violation}", file=sys.stderr)
    return 1

  print(
    f"coverage gate: {measured['total']['covered']}/"
    f"{measured['total']['active']} lines "
    f"({_percentage(measured['total']):.2f}%), no regressions"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
