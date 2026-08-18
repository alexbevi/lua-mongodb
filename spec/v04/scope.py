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
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
OUTPUT = ROOT / "spec" / "v04" / "scope.json"

RATCHETS = {
  "classified": 898,
  "exact_unified": 355,
  "passed": 851,
  "read_write_concern_passed": 48,
  "supported": 851,
}

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
  "SDAM-008",
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
  "LEG-001": "deprecated count retries are outside the v0.4 public API",
  "LEG-002": "deprecated count timeouts are outside the v0.4 public API",
  "LEG-003": "legacy mapReduce is outside the v0.4 public API",
  "LEG-004": "legacy mapReduce retries are outside the v0.4 public API",
  "LEG-005": "database aggregation is outside the v0.4 public API",
  "LEG-006": "database aggregate retries are outside the v0.4 public API",
  "LEG-007": "database aggregate timeouts are outside the v0.4 public API",
  "LEG-008": "advanced command cursors are outside the v0.4 public API",
  "LEG-009": "tailable cursors are outside the v0.4 public API",
  "LEG-010": "awaitData cursors are outside the v0.4 public API",
  "REL-053": "old-server compatibility branches are outside the v0.4 target",
}

TARGET_VERSION_EXCLUSIONS = {
  "server-discovery-and-monitoring/tests/unified/"
  "serverMonitoringMode.json::test[2]": (
    "polling behavior below MongoDB 4.4 is outside the v0.4 MongoDB 7.0 "
    "compatibility floor"
  ),
  "server-discovery-and-monitoring/tests/unified/"
  "serverMonitoringMode.json::test[4]": (
    "streaming behavior below MongoDB 4.4 is outside the v0.4 MongoDB 7.0 "
    "compatibility floor"
  ),
  "sessions/tests/snapshot-sessions-not-supported-client-error.json::test[1]": (
    "snapshot-session rejection on MongoDB 4.4 and older is outside the "
    "v0.4 MongoDB 7.0 compatibility floor"
  ),
  "sessions/tests/snapshot-sessions-not-supported-client-error.json::test[2]": (
    "snapshot-session rejection on MongoDB 4.4 and older is outside the "
    "v0.4 MongoDB 7.0 compatibility floor"
  ),
  "sessions/tests/snapshot-sessions-not-supported-client-error.json::test[3]": (
    "snapshot-session rejection on MongoDB 4.4 and older is outside the "
    "v0.4 MongoDB 7.0 compatibility floor"
  ),
  "read-write-concern/tests/operation/"
  "default-write-concern-3.4.json::test[4]": (
    "legacy mapReduce concern behavior requires MongoDB 3.4, below the "
    "v0.4 MongoDB 7.0 compatibility floor"
  ),
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


def load_executors(
  executor_path: Path = EXECUTORS,
) -> dict[str, dict[str, Any]]:
  return json.loads(executor_path.read_text(encoding="utf-8"))["tests"]


def load_capability_ratchets(
  capabilities_path: Path = CAPABILITIES,
) -> dict[str, int]:
  return json.loads(capabilities_path.read_text(encoding="utf-8"))["ratchets"]


def validate_execution(
  cases: dict[str, dict[str, Any]],
  report: dict[str, Any] | list[dict[str, Any]],
  expected_ratchets: dict[str, int],
) -> dict[str, int]:
  """Require exact passing execution rows for every unified v0.4 target."""
  reports = report if isinstance(report, list) else [report]
  required = {
    identity
    for identity, case in cases.items()
    if case.get("status") == "passed"
      and case.get("runner") == "spec/unified/execute.lua"
      and identity not in TARGET_VERSION_EXCLUSIONS
  }
  passed = set()

  for report_index, exact_report in enumerate(reports):
    if not isinstance(exact_report, dict) or exact_report.get("type") != "execution":
      raise ScopeError("v0.4 evidence is not a unified execution report")

    report_ratchets = exact_report.get("ratchets")
    if report_index == 0 and report_ratchets != expected_ratchets:
      raise ScopeError("v0.4 execution report ratchets do not match the manifest")
    if report_index > 0:
      if not isinstance(report_ratchets, dict) or set(report_ratchets) != set(expected_ratchets):
        raise ScopeError("v0.4 supplemental report ratchets are malformed")
      for name, value in report_ratchets.items():
        if not isinstance(value, int) or not 0 <= value <= expected_ratchets[name]:
          raise ScopeError("v0.4 supplemental report ratchets are malformed")

    report_rows = exact_report.get("tests")
    if not isinstance(report_rows, list):
      raise ScopeError("v0.4 execution report test rows must be an array")

    seen = set()
    for row in report_rows:
      if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        raise ScopeError("v0.4 execution report contains a malformed test row")

      identity = row["id"]
      if identity in seen:
        raise ScopeError(f"v0.4 execution report repeats {identity}")
      seen.add(identity)

      if identity not in required:
        continue

      status = row.get("status")
      if status == "passed":
        passed.add(identity)
      elif status != "environment_skipped":
        detail = row.get("error")
        suffix = f": {detail}" if isinstance(detail, str) and detail else ""
        raise ScopeError(
          f"v0.4 target did not pass exact execution: {identity}{suffix}"
        )

  missing = sorted(required - passed)
  if missing:
    raise ScopeError(f"v0.4 target did not pass exact execution: {missing[0]}")

  return {"passed": len(passed), "required": len(required)}


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  suites = report["suites"]
  summary = report["summary"]
  current = {
    "classified": summary["classified"],
    "exact_unified": report["evidence"]["exact_unified_cases"],
    "passed": summary["passed"],
    "read_write_concern_passed": suites["read-write-concern"].get(
      "passed", 0,
    ),
    "supported": summary["supported"],
  }

  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.4 {name} ratchet regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
  executors: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
  executors = load_executors() if executors is None else executors
  statuses = Counter()
  suites: dict[str, Counter[str]] = {
    suite: Counter() for suite in sorted(TARGET_SUITES)
  }
  planned_by_activity = Counter()
  excluded_by_activity = Counter()
  exact_unified = 0
  seen_target_version_exclusions = set()

  for identity, case in cases.items():
    status = case.get("status")
    owner = case.get("activity")
    suite = case.get("suite")

    if owner not in activities:
      raise ScopeError(f"unknown owner for {identity}: {owner}")

    if identity in TARGET_VERSION_EXCLUSIONS:
      if status not in {"passed", "deferred_unsupported", "excluded_scope"}:
        raise ScopeError(f"stale v0.4 target-version exclusion: {identity}")
      if status != "passed" and owner != "LEG-003":
        raise ScopeError(f"target-version exclusion has wrong owner: {identity}")
      seen_target_version_exclusions.add(identity)

    if status == "passed":
      runner = case.get("runner")
      evidence = case.get("last_execution")
      if not isinstance(runner, str) or not runner or runner.startswith("pending:"):
        raise ScopeError(f"passing v0.4 case has no exact runner: {identity}")
      if not isinstance(evidence, str) or not evidence:
        raise ScopeError(f"passing v0.4 case has no execution evidence: {identity}")

      if runner == "spec/unified/execute.lua":
        executor = executors.get(identity)
        if executor is None:
          raise ScopeError(f"passing v0.4 case has no exact executor: {identity}")
        if executor.get("environment") != case.get("required_environment"):
          raise ScopeError(f"v0.4 executor environment is stale for {identity}")
        exact_unified += 1

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

  missing_target_exclusions = (
    set(TARGET_VERSION_EXCLUSIONS) - seen_target_version_exclusions
  )
  if missing_target_exclusions:
    identity = sorted(missing_target_exclusions)[0]
    raise ScopeError(f"missing v0.4 target-version exclusion: {identity}")

  report = {
    "evidence": {
      "exact_unified_cases": exact_unified,
      "static_passing_cases": statuses["passed"] - exact_unified,
    },
    "excluded_by_activity": dict(sorted(excluded_by_activity.items())),
    "exclusion_reasons": EXCLUSION_REASONS,
    "planned_by_activity": dict(sorted(planned_by_activity.items())),
    "ratchets": RATCHETS,
    "schema_version": 2,
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
    "target_version_exclusions": TARGET_VERSION_EXCLUSIONS,
    "type": "v0.4-sharded-parity-scope",
  }

  if statuses["planned"]:
    raise ScopeError(
      f"v0.4 conformance still has {statuses['planned']} planned cases"
    )

  validate_scope_ratchets(report)
  return report


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
  parser.add_argument("--execution-report", action="append", type=Path)
  arguments = parser.parse_args()
  if arguments.check:
    check()
  else:
    write()
  generated = generate()
  report = generated["summary"]
  exact = ""
  if arguments.execution_report is not None:
    execution = [
      json.loads(report.read_text(encoding="utf-8"))
      for report in arguments.execution_report
    ]
    evidence = validate_execution(
      load_cases(),
      execution,
      load_capability_ratchets(),
    )
    exact = f", {evidence['passed']} exact unified cases passed"
  print(
    "v0.4 scope: "
    f"{report['supported']}/{report['classified']} supported, "
    f"{report['passed']} passed, {report['planned']} planned, "
    f"{report['excluded']} excluded{exact}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
