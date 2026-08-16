#!/usr/bin/env python3
"""Generate and validate the v0.4 sharded parity conformance boundary."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
OUTPUT = ROOT / "spec" / "v04" / "scope.json"

TARGET_SUITES = {
  "index-management",
  "initial-dns-seedlist-discovery",
  "read-write-concern",
  "run-command",
  "server-discovery-and-monitoring",
  "sessions",
  "transactions",
}

TARGET_OWNERS = {
  "ADV-005",
  "CFG-004",
  "CMAP-002",
  "CMAP-003",
  "CMAP-004",
  "DNS-001",
  "IDX-001",
  "IDX-002",
  "IDX-003",
  "IDX-004",
  "IDX-005",
  "IDX-006",
  "SDAM-004",
  "SDAM-005",
  "SDAM-006",
  "SDAM-007",
  "SES-004",
  "SES-005",
  "SES-006",
  "SES-007",
  "SES-008",
  "TXN-003",
  "TXN-004",
  "TXN-005",
  "TXN-006",
  "TXN-007",
}

EXCLUSION_REASONS = {
  "ADV-006": "load-balanced deployment behavior is outside the v0.4 sharded target",
  "ADV-007": "client bulk write remains a separate post-v0.4 capability",
  "ADV-009": "logging and backpressure remain separate post-v0.4 capabilities",
  "ADV-011": "legacy count, mapReduce, and tailable cursors are outside the v0.4 public API",
}


class ScopeError(ValueError):
  """Raised when the v0.4 conformance boundary loses accountable ownership."""


def load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  plan = json.loads(plan_path.read_text(encoding="utf-8"))
  progress = json.loads(progress_path.read_text(encoding="utf-8"))["activities"]
  return {
    activity["id"]: {
      "milestone": activity["milestone"],
      "status": progress.get(activity["id"], {}).get("status", "pending"),
      "track": activity.get("track", ""),
    }
    for activity in plan["activities"]
  }


def load_cases(ledger_path: Path = LEDGER) -> dict[str, dict[str, Any]]:
  ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
  return {
    identity: case
    for identity, case in ledger["cases"].items()
    if case["suite"] in TARGET_SUITES
  }


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  statuses = Counter()
  suites: dict[str, Counter[str]] = {
    suite: Counter() for suite in sorted(TARGET_SUITES)
  }
  planned_by_activity = Counter()
  excluded_by_activity = Counter()

  for identity, case in cases.items():
    status = case.get("status")
    owner = case.get("activity")
    suite = case.get("suite")

    if owner not in activities:
      raise ScopeError(f"unknown owner for {identity}: {owner}")

    if status == "passed":
      classification = "passed"
    elif status not in {"deferred_unsupported", "excluded_scope"}:
      raise ScopeError(f"unknown conformance status for {identity}: {status}")
    elif owner in TARGET_OWNERS:
      activity = activities[owner]
      if activity["track"] != "v0-4-sharded-parity":
        raise ScopeError(f"v0.4 owner is outside the declared track for {identity}: {owner}")
      if activity["status"] == "completed":
        raise ScopeError(f"completed owner {owner} still defers {identity}")
      classification = "planned"
      planned_by_activity[owner] += 1
    elif owner in EXCLUSION_REASONS:
      classification = "excluded"
      excluded_by_activity[owner] += 1
    else:
      raise ScopeError(f"unaccounted v0.4 case {identity}: {owner}")

    statuses[classification] += 1
    suites[suite][classification] += 1

  supported = statuses["passed"] + statuses["planned"]
  return {
    "excluded_by_activity": dict(sorted(excluded_by_activity.items())),
    "exclusion_reasons": EXCLUSION_REASONS,
    "planned_by_activity": dict(sorted(planned_by_activity.items())),
    "schema_version": 1,
    "suites": {
      suite: dict(sorted(counts.items()))
      for suite, counts in suites.items()
    },
    "summary": {
      "classified": len(cases),
      "excluded": statuses["excluded"],
      "passed": statuses["passed"],
      "planned": statuses["planned"],
      "supported": supported,
    },
    "target_owners": sorted(TARGET_OWNERS),
    "type": "v0.4-sharded-parity-scope",
  }


def generate() -> dict[str, Any]:
  return classify(load_cases(), load_activities())


def write() -> None:
  OUTPUT.write_text(
    json.dumps(generate(), indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
  )


def check() -> None:
  expected = generate()
  actual = json.loads(OUTPUT.read_text(encoding="utf-8"))
  if actual != expected:
    raise ScopeError("generated v0.4 scope is stale")


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args()
  if arguments.check:
    check()
  else:
    write()
  report = generate()["summary"]
  print(
    "v0.4 scope: "
    f"{report['supported']}/{report['classified']} supported, "
    f"{report['passed']} passed, {report['planned']} planned, "
    f"{report['excluded']} excluded"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
