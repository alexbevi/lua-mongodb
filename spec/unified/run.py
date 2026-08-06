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
DEFAULT_PLAN = ROOT / "planning" / "plan.json"
VALID_STATUSES = {"deferred", "runnable"}
REPORT_VERSION = 2


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


def load_activity_ids(path: Path) -> set[str]:
  try:
    plan = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load roadmap {path}: {exc}") from exc

  activities = plan.get("activities")

  if not isinstance(activities, list):
    raise CapabilityError("roadmap activities must be an array")

  result = {
    value.get("id") for value in activities
    if isinstance(value, dict) and isinstance(value.get("id"), str)
  }

  if len(result) != len(activities):
    raise CapabilityError("every roadmap activity must have a unique string id")

  return result


def classify_fixtures(
  discovered: list[str],
  classifications: dict[str, Any],
  activity_ids: set[str] | None = None,
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

    if activity_ids is not None and activity not in activity_ids:
      raise CapabilityError(
        f"classification for {path} has unknown activity owner: {activity}"
      )

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


def build_inventory_report(fixtures: list[dict[str, Any]]) -> dict[str, Any]:
  """Return a deterministic inventory with one stable identity per test."""
  files = []
  tests = []

  for fixture in sorted(fixtures, key=lambda value: value["path"]):
    path = fixture["path"]
    descriptions = fixture["tests"]
    files.append({
      "description": fixture["description"],
      "path": path,
      "schema_version": fixture["schema_version"],
      "tests": len(descriptions),
    })

    for index, description in enumerate(descriptions, 1):
      tests.append({
        "description": description,
        "fixture": path,
        "id": f"{path}::test[{index}]",
        "index": index,
      })

  return {
    "files": files,
    "report_version": REPORT_VERSION,
    "summary": {"files": len(files), "tests": len(tests)},
    "tests": tests,
    "type": "inventory",
  }


def build_report(classifications: list[dict[str, str]]) -> dict[str, Any]:
  """Build an execution report without conflating deferral with execution."""
  fixtures = []
  summary = {
    "conformant": False,
    "deferred_unsupported": 0,
    "environment_skipped": 0,
    "executed": 0,
    "excluded_scope": 0,
    "failed": 0,
    "invalid_or_incompatible": 0,
    "passed": 0,
    "selected": len(classifications),
  }

  for classification in classifications:
    item = dict(classification)

    if item["status"] == "deferred":
      item["status"] = "deferred_unsupported"
      summary["deferred_unsupported"] += 1
    else:
      item["status"] = "failed"
      item["error"] = "runnable fixture has no registered executor"
      summary["failed"] += 1

    fixtures.append(item)

  return {
    "fixtures": fixtures,
    "report_version": REPORT_VERSION,
    "summary": summary,
    "type": "execution",
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
  parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
  parser.add_argument("--include", action="append")
  parser.add_argument("--report", metavar="PATH")
  arguments = parser.parse_args(argv)

  try:
    discovered = discover_fixtures(arguments.source)

    if not discovered:
      raise CapabilityError("unified fixture discovery found no files")

    manifest = load_manifest(arguments.manifest)
    activity_ids = load_activity_ids(arguments.plan)
    classified = classify_fixtures(discovered, manifest["fixtures"], activity_ids)
    selected = select_classifications(classified, arguments.include)
    report = build_report(selected)
    write_report(report, arguments.report)
  except CapabilityError as exc:
    print(f"unified capabilities: {exc}", file=sys.stderr)
    return 2

  summary = report["summary"]
  print(
    f"unified execution: {summary['executed']} executed, "
    f"{summary['passed']} passed, {summary['failed']} failed, "
    f"{summary['environment_skipped']} environment-skipped, "
    f"{summary['deferred_unsupported']} deferred-unsupported; "
    f"conformant={str(summary['conformant']).lower()}",
    file=sys.stderr if arguments.report == "-" else sys.stdout,
  )
  return 1 if summary["failed"] else 0


if __name__ == "__main__":
  raise SystemExit(main())
