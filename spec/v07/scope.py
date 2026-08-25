#!/usr/bin/env python3
"""Generate and validate the v0.7 client bulk-write conformance boundary."""

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
OUTPUT = ROOT / "spec" / "v07" / "scope.json"

RATCHETS = {
  "classified": 71,
  "exact_unified": 71,
  "passed": 71,
  "supported": 71,
}

IMPLEMENTED_OWNERS = {
  "ADV-007",
  *(f"CBW-{index:03d}" for index in range(1, 19)),
}
CLOSURE_OWNER = "REL-055"
TARGET_OWNERS = IMPLEMENTED_OWNERS | {CLOSURE_OWNER}
TARGET_VERSION_EXCLUSIONS: dict[str, str] = {}
MACOS_CI_TIMING_SKIPS = frozenset({
  "client-side-operations-timeout/tests/bulkWrite.json::test[1]",
})


class ScopeError(ValueError):
  """Raised when the v0.7 conformance boundary loses exact evidence."""


def load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  plan = json.loads(plan_path.read_text(encoding="utf-8"))
  progress = json.loads(progress_path.read_text(encoding="utf-8"))["activities"]
  return {
    activity["id"]: {
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
    if case.get("activity") in TARGET_OWNERS
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
  *,
  allow_macos_ci_timing_skips: bool = False,
) -> dict[str, int]:
  reports = report if isinstance(report, list) else [report]
  required = {
    identity
    for identity, case in cases.items()
    if case.get("status") == "passed"
  }
  passed = set()
  macos_timing_skipped = set()

  for report_index, exact_report in enumerate(reports):
    if not isinstance(exact_report, dict) or exact_report.get("type") != "execution":
      raise ScopeError("v0.7 evidence is not a unified execution report")

    report_ratchets = exact_report.get("ratchets")
    if report_index == 0 and report_ratchets != expected_ratchets:
      raise ScopeError("v0.7 execution report ratchets do not match the manifest")
    if report_index > 0:
      if not isinstance(report_ratchets, dict) \
          or set(report_ratchets) != set(expected_ratchets):
        raise ScopeError("v0.7 supplemental report ratchets are malformed")
      if any(
        not isinstance(value, int) or not 0 <= value <= expected_ratchets[name]
        for name, value in report_ratchets.items()
      ):
        raise ScopeError("v0.7 supplemental report ratchets are malformed")

    rows = exact_report.get("tests")
    if not isinstance(rows, list):
      raise ScopeError("v0.7 execution report test rows must be an array")

    seen = set()
    for row in rows:
      if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        raise ScopeError("v0.7 execution report contains a malformed test row")
      identity = row["id"]
      if identity in seen:
        raise ScopeError(f"v0.7 execution report repeats {identity}")
      seen.add(identity)
      if identity not in required:
        continue
      status = row.get("status")
      if status == "passed":
        passed.add(identity)
      elif (
        status == "environment_skipped"
        and allow_macos_ci_timing_skips
        and identity in MACOS_CI_TIMING_SKIPS
      ):
        macos_timing_skipped.add(identity)
      elif status != "environment_skipped":
        detail = row.get("error")
        suffix = f": {detail}" if isinstance(detail, str) and detail else ""
        raise ScopeError(
          f"v0.7 target did not pass exact execution: {identity}{suffix}"
        )

  macos_timing_skipped -= passed
  missing = sorted(required - passed - macos_timing_skipped)
  if missing:
    raise ScopeError(f"v0.7 target did not pass exact execution: {missing[0]}")

  return {
    "macos_timing_skipped": len(macos_timing_skipped),
    "passed": len(passed),
    "required": len(required),
  }


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  summary = report["summary"]
  current = {
    "classified": summary["classified"],
    "exact_unified": report["evidence"]["exact_unified_cases"],
    "passed": summary["passed"],
    "supported": summary["supported"],
  }
  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.7 {name} ratchet regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
  executors: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
  executors = load_executors() if executors is None else executors
  statuses = Counter()
  suites: dict[str, Counter[str]] = {}
  passed_by_activity = Counter()
  exact_unified = 0

  for identity, case in cases.items():
    owner = case.get("activity")
    status = case.get("status")
    suite = case.get("suite")
    suites.setdefault(suite, Counter())

    if owner not in activities:
      raise ScopeError(f"unknown owner for {identity}: {owner}")
    if owner not in TARGET_OWNERS:
      raise ScopeError(f"v0.7 case has an unaccounted owner: {identity}")
    if status != "passed":
      raise ScopeError(f"v0.7 case remains deferred: {identity}")

    activity = activities[owner]
    if activity["track"] != "v0-5-v0-7-api":
      raise ScopeError(f"v0.7 owner is outside the declared track: {identity}")
    if owner == CLOSURE_OWNER:
      if activity["status"] not in {"in_progress", "completed"}:
        raise ScopeError(f"v0.7 closure owner is not active for {identity}")
    elif activity["status"] != "completed":
      raise ScopeError(f"v0.7 passing owner is incomplete for {identity}: {owner}")

    if case.get("runner") != "spec/unified/execute.lua":
      raise ScopeError(f"passing v0.7 case has no exact runner: {identity}")
    if not case.get("last_execution"):
      raise ScopeError(f"passing v0.7 case has no execution evidence: {identity}")

    executor = executors.get(identity)
    if executor is None:
      raise ScopeError(f"passing v0.7 case has no exact executor: {identity}")
    if executor.get("environment") != case.get("required_environment"):
      raise ScopeError(f"v0.7 executor environment is stale for {identity}")

    exact_unified += 1
    passed_by_activity[owner] += 1
    statuses["passed"] += 1
    suites[suite]["passed"] += 1

  report = {
    "evidence": {"exact_unified_cases": exact_unified},
    "passed_by_activity": dict(sorted(passed_by_activity.items())),
    "ratchets": RATCHETS,
    "schema_version": 1,
    "suites": {
      suite: dict(sorted(counts.items()))
      for suite, counts in sorted(suites.items())
    },
    "summary": {
      "classified": len(cases),
      "excluded": 0,
      "passed": statuses["passed"],
      "planned": 0,
      "supported": statuses["passed"],
    },
    "target_owners": sorted(TARGET_OWNERS),
    "target_version_exclusions": TARGET_VERSION_EXCLUSIONS,
    "type": "v0.7-client-bulk-write-scope",
  }
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
    raise ScopeError("generated v0.7 scope is stale")


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true")
  parser.add_argument("--execution-report", action="append", type=Path)
  parser.add_argument("--allow-macos-ci-timing-skips", action="store_true")
  arguments = parser.parse_args()
  if arguments.check:
    check()
  else:
    write()
  generated = generate()
  summary = generated["summary"]
  exact = ""
  if arguments.execution_report is not None:
    reports = [
      json.loads(path.read_text(encoding="utf-8"))
      for path in arguments.execution_report
    ]
    evidence = validate_execution(
      load_cases(),
      reports,
      load_capability_ratchets(),
      allow_macos_ci_timing_skips=arguments.allow_macos_ci_timing_skips,
    )
    if evidence["macos_timing_skipped"]:
      exact = (
        f"; exact evidence {evidence['passed']} passed + "
        f"{evidence['macos_timing_skipped']} explicit macOS timing skips/"
        f"{evidence['required']} required"
      )
    else:
      exact = f"; exact evidence {evidence['passed']}/{evidence['required']}"
  print(
    "v0.7 client bulk-write scope: "
    f"{summary['classified']} classified, {summary['passed']} passed, "
    f"{summary['excluded']} excluded{exact}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
