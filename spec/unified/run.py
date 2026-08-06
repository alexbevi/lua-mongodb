#!/usr/bin/env python3
"""Discover and report pinned MongoDB unified test fixture capabilities."""

from __future__ import annotations

import argparse
import fnmatch
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "planning" / "specifications" / "source"
DEFAULT_MANIFEST = ROOT / "spec" / "unified" / "capabilities.json"
VALID_STATUSES = {"deferred", "runnable"}


class CapabilityError(ValueError):
  """Raised when fixture discovery and the capability manifest diverge."""


def discover_fixtures(source: Path, includes: list[str] | None = None) -> list[str]:
  """Return sorted source-relative unified JSON fixture paths."""
  if not source.is_dir():
    raise CapabilityError(f"unified specification source does not exist: {source}")

  patterns = includes or ["*"]
  fixtures = []

  for path in source.rglob("*.json"):
    relative = path.relative_to(source)
    parts = relative.parts

    if len(parts) < 4 or parts[-3:-1] != ("tests", "unified"):
      continue

    name = relative.as_posix()

    if any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
      fixtures.append(name)

  return sorted(fixtures)


def load_manifest(path: Path) -> dict[str, Any]:
  try:
    manifest = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load capability manifest {path}: {exc}") from exc

  if manifest.get("schema_version") != 1:
    raise CapabilityError("capability manifest schema_version must be 1")

  fixtures = manifest.get("fixtures")

  if not isinstance(fixtures, dict):
    raise CapabilityError("capability manifest fixtures must be an object")

  return manifest


def classify_fixtures(
  discovered: list[str],
  classifications: dict[str, Any],
) -> list[dict[str, str]]:
  """Validate complete coverage and return normalized classifications."""
  discovered_set = set(discovered)
  classified_set = set(classifications)
  missing = sorted(discovered_set - classified_set)
  stale = sorted(classified_set - discovered_set)

  if missing:
    raise CapabilityError(f"unclassified fixture: {missing[0]}")

  if stale:
    raise CapabilityError(f"manifest references undiscovered fixture: {stale[0]}")

  result = []

  for path in discovered:
    value = classifications[path]

    if not isinstance(value, dict):
      raise CapabilityError(f"classification for {path} must be an object")

    status = value.get("status")
    reason = value.get("reason")
    activity = value.get("activity")

    if status not in VALID_STATUSES:
      raise CapabilityError(f"classification for {path} has unknown status: {status}")

    if status == "deferred" and (not isinstance(reason, str) or not reason.strip()):
      raise CapabilityError(f"deferred fixture {path} must have a reason")

    if status == "runnable" and reason is not None:
      raise CapabilityError(f"runnable fixture {path} must not have a deferred reason")

    if not isinstance(activity, str) or not activity:
      raise CapabilityError(f"classification for {path} must name an activity")

    row = {"activity": activity, "path": path, "status": status}

    if reason is not None:
      row["reason"] = reason

    result.append(row)

  return result


def select_classifications(
  classifications: list[dict[str, str]],
  includes: list[str] | None,
) -> list[dict[str, str]]:
  patterns = includes or ["*"]
  return [
    value for value in classifications
    if any(fnmatch.fnmatchcase(value["path"], pattern) for pattern in patterns)
  ]


def build_report(classifications: list[dict[str, str]]) -> dict[str, Any]:
  fixtures = []
  summary = {"deferred": 0, "failed": 0, "passed": 0, "selected": len(classifications)}

  for classification in classifications:
    item = dict(classification)

    if item["status"] == "deferred":
      summary["deferred"] += 1
    else:
      item["status"] = "failed"
      item["error"] = "runnable fixture has no registered executor"
      summary["failed"] += 1

    fixtures.append(item)

  return {
    "fixtures": fixtures,
    "report_version": 1,
    "summary": summary,
  }


def write_report(report: dict[str, Any], destination: str | None) -> None:
  encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"

  if destination == "-":
    print(encoded, end="")
  elif destination:
    Path(destination).write_text(encoded, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
  parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
  parser.add_argument("--include", action="append")
  parser.add_argument("--report", metavar="PATH")
  arguments = parser.parse_args(argv)

  try:
    discovered = discover_fixtures(arguments.source)

    if not discovered:
      raise CapabilityError("unified fixture discovery found no files")

    manifest = load_manifest(arguments.manifest)
    classified = classify_fixtures(discovered, manifest["fixtures"])
    selected = select_classifications(classified, arguments.include)
    report = build_report(selected)
    write_report(report, arguments.report)
  except CapabilityError as exc:
    print(f"unified capabilities: {exc}", file=sys.stderr)
    return 2

  summary = report["summary"]
  print(
    f"{summary['selected']} unified fixtures classified: "
    f"{summary['deferred']} deferred, {summary['passed']} passed, "
    f"{summary['failed']} failed",
    file=sys.stderr if arguments.report == "-" else sys.stdout,
  )
  return 1 if summary["failed"] else 0


if __name__ == "__main__":
  raise SystemExit(main())
