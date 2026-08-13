#!/usr/bin/env python3
"""Validate and report production-core v1 release readiness."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.compatibility import matrix  # noqa: E402
from spec.release import scope  # noqa: E402


PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
OUTPUT = ROOT / "spec" / "release" / "checklist.json"
ROCKSPEC = ROOT / "mongodb-0.1.0-1.rockspec"
RELEASE_VERSION = "0.1.0"
ROCKSPEC_VERSION = f"{RELEASE_VERSION}-1"
CLASSIFIED_CASES = 5524
MINIMUM_PASSED_CASES = 3570
MAXIMUM_POST_V1_EXCLUSIONS = 1954
AUDITS = {
  "cleanup": ["REL-042", "REL-043"],
  "packaging": ["REL-007"],
  "security": ["REL-008"],
}


class ChecklistError(ValueError):
  """Raised when the production-core release is not ready."""


def load_json(path: Path) -> dict[str, Any]:
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ChecklistError(f"cannot read release input {path}: {exc}") from exc


def require_text(path: Path, expected: str) -> None:
  try:
    contents = path.read_text(encoding="utf-8")
  except OSError as exc:
    raise ChecklistError(f"cannot read release document {path}: {exc}") from exc

  if expected not in contents:
    raise ChecklistError(f"{path.relative_to(ROOT)} is missing {expected!r}")


def completed_activity(progress: dict[str, Any], activity_id: str) -> None:
  activity = progress.get("activities", {}).get(activity_id, {})

  if activity.get("status") != "completed":
    raise ChecklistError(f"release activity is not completed: {activity_id}")

  green = [
    item
    for item in activity.get("evidence", [])
    if item.get("phase") == "green" and item.get("exit_code") == 0
  ]

  if not green:
    raise ChecklistError(f"release activity has no green evidence: {activity_id}")


def release_metadata() -> dict[str, str]:
  if not ROCKSPEC.exists():
    raise ChecklistError(f"release rockspec is missing: {ROCKSPEC.name}")

  rockspec = ROCKSPEC.read_text(encoding="utf-8")
  package = re.search(r'^package = "([^"]+)"$', rockspec, re.MULTILINE)
  version = re.search(r'^version = "([^"]+)"$', rockspec, re.MULTILINE)

  if package is None or package.group(1) != "mongodb":
    raise ChecklistError("release rockspec package must be mongodb")

  if version is None or version.group(1) != ROCKSPEC_VERSION:
    raise ChecklistError(
      f"release rockspec version must be {ROCKSPEC_VERSION}"
    )

  require_text(
    ROOT / "src" / "mongodb" / "handshake" / "metadata.lua",
    f'local DRIVER_VERSION = "{RELEASE_VERSION}"',
  )
  require_text(
    ROOT / "README.md",
    f"Production-core v1 is version `{RELEASE_VERSION}`.",
  )
  require_text(
    ROOT / "CHANGELOG.md",
    f"## [{RELEASE_VERSION}] - 2026-08-09",
  )
  require_text(
    ROOT / "docs" / "ARCHITECTURE.md",
    "Status: production-core v1 release-ready.",
  )

  return {
    "package": package.group(1),
    "rockspec": ROCKSPEC.name,
    "rockspec_version": version.group(1),
    "version": RELEASE_VERSION,
  }


def generate() -> dict[str, Any]:
  plan = load_json(PLAN)
  progress = load_json(PROGRESS)
  ledger = load_json(LEDGER)
  activities = {
    activity["id"]: activity
    for activity in plan.get("activities", [])
  }

  production_core = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("milestone") == "production-core-v1"
      and activity.get("id") != "REL-009"
  ]

  for activity_id in production_core:
    completed_activity(progress, activity_id)

  for activity_ids in AUDITS.values():
    for activity_id in activity_ids:
      if activity_id not in activities:
        raise ChecklistError(f"unknown release audit activity: {activity_id}")

      completed_activity(progress, activity_id)

  scope_report = scope.generate()
  statuses = scope_report.get("statuses", {})
  classified = sum(statuses.values())
  applicable_gaps = scope_report.get("deferred_by_scope", {}).get(
    "applicable-release-gap",
    0,
  )
  post_v1_exclusions = scope_report.get("deferred_by_scope", {}).get(
    "post-v1-exclusion",
    0,
  )
  ledger_summary = ledger.get("summary", {})

  if applicable_gaps != 0:
    raise ChecklistError(
      f"production-core release has {applicable_gaps} applicable gaps"
    )

  if classified != scope_report.get("total_cases"):
    raise ChecklistError("release scope contains unclassified cases")

  if classified != CLASSIFIED_CASES:
    raise ChecklistError(
      f"release scope must classify {CLASSIFIED_CASES} pinned cases"
    )

  if statuses.get("passed", 0) < MINIMUM_PASSED_CASES:
    raise ChecklistError("production-core passing-case ratchet regressed")

  if post_v1_exclusions > MAXIMUM_POST_V1_EXCLUSIONS:
    raise ChecklistError("production-core post-v1 exclusions increased")

  if ledger_summary.get("cases") != classified:
    raise ChecklistError("conformance ledger and release scope totals differ")

  if ledger_summary.get("statuses") != statuses:
    raise ChecklistError("conformance ledger and release scope statuses differ")

  compatibility = matrix.validate(matrix.load())
  profiles = sum(len(server["profiles"]) for server in compatibility["servers"])
  fast_workflow = ROOT / ".github" / "workflows" / "ci.yml"

  for expected in (
    "portable:",
    "compatibility-smoke:",
    "make check-fast",
    "planning/update_plan.py check --strict",
  ):
    require_text(fast_workflow, expected)

  full_workflow = ROOT / ".github" / "workflows" / "full-conformance.yml"

  for expected in (
    "linux-quality:",
    "linux-unified:",
    "linux-aggregate:",
    "macos:",
    "compatibility:",
    "make check-fast test-coverage",
  ):
    require_text(full_workflow, expected)

  return {
    "gates": {
      "ci": [
        "fast-compatibility-smoke",
        "fast-portable",
        "full-compatibility",
        "full-linux-aggregate",
        "full-linux-quality",
        "full-linux-unified",
        "full-macos",
      ],
      "compatibility": {
        "profiles": profiles,
        "rows": len(compatibility["servers"]),
      },
      "completed_audits": AUDITS,
      "conformance": {
        "applicable_gaps": applicable_gaps,
        "classified_cases": classified,
        "passed_cases": statuses.get("passed", 0),
        "post_v1_exclusions": post_v1_exclusions,
      },
      "production_core_prerequisites": len(production_core),
    },
    "ready": True,
    "release": release_metadata(),
    "schema_version": 1,
    "type": "production-core-release-checklist",
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  args = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (ChecklistError, matrix.MatrixError, scope.ScopeError) as exc:
    print(f"release checklist: {exc}")
    return 2

  if args.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("release checklist report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  conformance = report["gates"]["conformance"]
  compatibility = report["gates"]["compatibility"]
  print(
    f"release checklist: {report['release']['version']} ready; "
    f"{conformance['classified_cases']} classified cases, "
    f"{conformance['applicable_gaps']} applicable gaps, "
    f"{compatibility['rows']} compatibility rows"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
