#!/usr/bin/env python3
"""Validate and report production-core v1 conformance ownership."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
OUTPUT = ROOT / "spec" / "release" / "scope.json"
AMBIGUOUS_OWNERS = {"REL-001", "REL-009"}
RELEASE_FIXTURE_OWNERS = {
  "REL-002", "REL-003", "REL-004", "REL-005", "REL-006", "REL-010", "REL-011",
  "REL-012", "REL-013", "REL-014", "REL-015", "REL-016", "REL-017",
  "REL-018", "REL-019", "REL-020", "REL-021", "REL-022", "REL-023",
  "REL-024", "REL-025", "REL-026", "REL-027", "REL-028", "REL-029",
  "REL-030",
}
POST_V1_REASONS = {
  "ADV-001": "change streams are outside production-core v1",
  "ADV-002": "GridFS is outside production-core v1",
  "ADV-003": "SRV and TXT discovery are outside production-core v1",
  "ADV-004": "wire compression is outside production-core v1",
  "ADV-005": "sharded deployment behavior is outside production-core v1",
  "ADV-006": "load-balanced deployment behavior is outside production-core v1",
  "ADV-007": "client bulk write is outside production-core v1",
  "ADV-008": "advanced authentication mechanisms are outside production-core v1",
  "ADV-009": "logging, telemetry, and backpressure are outside production-core v1",
  "ADV-010": "client-side encryption requires a separate post-v1 design",
  "ADV-011": "expanded command, cursor, and session APIs are outside production-core v1",
  "ADV-012": "proxy transports are outside production-core v1",
}


class ScopeError(ValueError):
  """Raised when release conformance lacks an accountable owner."""


def load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  plan = json.loads(plan_path.read_text(encoding="utf-8"))
  progress = json.loads(progress_path.read_text(encoding="utf-8"))
  states = progress.get("activities", {})
  return {
    activity["id"]: {
      "milestone": activity["milestone"],
      "status": states.get(activity["id"], {}).get("status", "pending"),
    }
    for activity in plan["activities"]
  }


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  statuses = Counter()
  deferred_by_activity = Counter()
  deferred_by_scope = Counter()

  for identity, case in cases.items():
    status = case.get("status")
    owner = case.get("activity")

    if status not in {"deferred_unsupported", "excluded_scope", "passed"}:
      raise ScopeError(f"unknown conformance status for {identity}: {status}")

    if owner not in activities:
      raise ScopeError(f"unknown conformance owner for {identity}: {owner}")

    statuses[status] += 1

    if status == "passed":
      continue

    if owner in AMBIGUOUS_OWNERS:
      raise ScopeError(f"ambiguous release owner {owner}: {identity}")

    reason = case.get("reason")

    if not isinstance(reason, str) or not reason.strip():
      raise ScopeError(f"deferred conformance case has no reason: {identity}")

    activity = activities[owner]

    if activity["status"] == "completed":
      raise ScopeError(f"deferred case is owned by completed activity {owner}: {identity}")

    if activity["milestone"] == "production-core-v1":
      if owner not in RELEASE_FIXTURE_OWNERS:
        raise ScopeError(f"invalid production-core release owner {owner}: {identity}")

      scope = "applicable-release-gap"
    elif activity["milestone"] == "post-v1":
      if owner not in POST_V1_REASONS:
        raise ScopeError(f"post-v1 owner has no scope reason {owner}: {identity}")

      scope = "post-v1-exclusion"
    else:
      raise ScopeError(f"unknown release milestone for {identity}: {activity['milestone']}")

    deferred_by_activity[owner] += 1
    deferred_by_scope[scope] += 1

  return {
    "deferred_by_activity": dict(sorted(deferred_by_activity.items())),
    "deferred_by_scope": dict(sorted(deferred_by_scope.items())),
    "post_v1_reasons": POST_V1_REASONS,
    "schema_version": 1,
    "statuses": dict(sorted(statuses.items())),
    "total_cases": len(cases),
    "type": "production-core-release-scope",
  }


def release_cases(
  capabilities_path: Path = CAPABILITIES,
  ledger_path: Path = LEDGER,
) -> dict[str, dict[str, Any]]:
  capabilities = json.loads(capabilities_path.read_text(encoding="utf-8"))["tests"]
  ledger = json.loads(ledger_path.read_text(encoding="utf-8"))["cases"]
  result = {}

  for identity, record in ledger.items():
    value = {
      "activity": record["activity"],
      "status": record["status"],
    }

    if record["status"] != "passed":
      capability = capabilities.get(identity)
      value["reason"] = (
        capability.get("reason")
        if capability is not None
        else POST_V1_REASONS.get(record["activity"])
        or f"awaits {record['activity']} conformance"
      )

    result[identity] = value

  return result


def generate() -> dict[str, Any]:
  return classify(release_cases(), load_activities())


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  args = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"release scope: {exc}")
    return 2

  if args.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("release scope report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  scopes = report["deferred_by_scope"]
  print(
    f"release scope: {report['total_cases']} cases; "
    f"{scopes.get('applicable-release-gap', 0)} applicable gaps, "
    f"{scopes.get('post-v1-exclusion', 0)} post-v1 exclusions"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
