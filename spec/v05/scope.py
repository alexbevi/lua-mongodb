#!/usr/bin/env python3
"""Generate and validate the v0.5 change-stream conformance boundary."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.conformance.provenance import specifications_commit  # noqa: E402

PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
OUTPUT = ROOT / "spec" / "v05" / "scope.json"

RATCHETS = {
  "classified": 195,
  "exact_unified": 176,
  "passed": 176,
  "supported": 176,
}

TARGET_OWNERS = {
  "ADV-001",
  "CS-001",
  "CS-002",
  "CS-003",
  "CS-004",
  "CS-005",
  "CS-006",
  "CS-007",
  "CS-008",
  "CS-009",
  "CS-010",
  "CS-011",
  "CS-012",
  "REL-051",
}

MACOS_CI_TIMING_SKIPS = frozenset({
  "client-side-operations-timeout/tests/change-streams.json::test[4]",
  "client-side-operations-timeout/tests/change-streams.json::test[5]",
  "client-side-operations-timeout/tests/change-streams.json::test[6]",
})

LEGACY_RESUME_REASON = (
  "MongoDB 4.2-only resumable-code behavior is below the v0.5 MongoDB 7.0 "
  "compatibility floor"
)
TARGET_VERSION_EXCLUSIONS = {
  **{
    "change-streams/tests/unified/"
    f"change-streams-resume-allowlist.json::test[{index}]": (
      LEGACY_RESUME_REASON
    )
    for index in range(2, 18)
  },
  "change-streams/tests/unified/"
  "change-streams-resume-errorLabels.json::test[13]": (
    "pre-7.0 StaleShardVersion error-label behavior is below the v0.5 "
    "MongoDB 7.0 compatibility floor"
  ),
  "change-streams/tests/unified/change-streams.json::test[3]": (
    "document comment behavior capped at MongoDB 4.2 is below the v0.5 "
    "MongoDB 7.0 compatibility floor"
  ),
  "change-streams/tests/unified/change-streams.json::test[6]": (
    "getMore comment behavior capped below MongoDB 4.4 is below the v0.5 "
    "MongoDB 7.0 compatibility floor"
  ),
}


class ScopeError(ValueError):
  """Raised when the v0.5 conformance boundary loses exact evidence."""


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


def is_target_case(identity: str, case: dict[str, Any]) -> bool:
  suite = case.get("suite")
  if suite == "change-streams":
    return True
  if suite == "retryable-reads":
    if "changeStreams-" in identity:
      return True
    return any(
      identity.endswith(f"handshakeError.json::test[{index}]")
      for index in (5, 6, 13, 14, 31, 32)
    )
  return (
    suite == "client-side-operations-timeout"
    and case.get("activity") == "CS-008"
  )


def load_cases(ledger_path: Path = LEDGER) -> dict[str, dict[str, Any]]:
  ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
  return {
    identity: case
    for identity, case in ledger["cases"].items()
    if is_target_case(identity, case)
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
  allow_macos_ci_timing_skips: bool = False,
) -> dict[str, int]:
  """Require v0.5 passes, optionally accepting named macOS timing skips."""
  reports = report if isinstance(report, list) else [report]
  required = {
    identity
    for identity, case in cases.items()
    if case.get("status") == "passed"
      and case.get("runner") == "spec/unified/execute.lua"
      and identity not in TARGET_VERSION_EXCLUSIONS
  }
  passed = set()
  macos_timing_skipped = set()

  for report_index, exact_report in enumerate(reports):
    if not isinstance(exact_report, dict) or exact_report.get("type") != "execution":
      raise ScopeError("v0.5 evidence is not a unified execution report")

    report_ratchets = exact_report.get("ratchets")
    if report_index == 0 and report_ratchets != expected_ratchets:
      raise ScopeError("v0.5 execution report ratchets do not match the manifest")
    if report_index > 0:
      if not isinstance(report_ratchets, dict) or set(report_ratchets) != set(expected_ratchets):
        raise ScopeError("v0.5 supplemental report ratchets are malformed")
      for name, value in report_ratchets.items():
        if not isinstance(value, int) or not 0 <= value <= expected_ratchets[name]:
          raise ScopeError("v0.5 supplemental report ratchets are malformed")

    report_rows = exact_report.get("tests")
    if not isinstance(report_rows, list):
      raise ScopeError("v0.5 execution report test rows must be an array")

    seen = set()
    for row in report_rows:
      if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        raise ScopeError("v0.5 execution report contains a malformed test row")

      identity = row["id"]
      if identity in seen:
        raise ScopeError(f"v0.5 execution report repeats {identity}")
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
          f"v0.5 target did not pass exact execution: {identity}{suffix}"
        )

  macos_timing_skipped -= passed
  missing = sorted(required - passed - macos_timing_skipped)
  if missing:
    raise ScopeError(f"v0.5 target did not pass exact execution: {missing[0]}")

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
        f"v0.5 {name} ratchet regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
  executors: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
  executors = load_executors() if executors is None else executors
  statuses = Counter()
  suites: dict[str, Counter[str]] = {
    suite: Counter()
    for suite in (
      "change-streams",
      "client-side-operations-timeout",
      "retryable-reads",
    )
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
        raise ScopeError(f"stale v0.5 target-version exclusion: {identity}")
      if status != "passed" and owner != "REL-053":
        raise ScopeError(f"target-version exclusion has wrong owner: {identity}")
      seen_target_version_exclusions.add(identity)

    if status == "passed":
      runner = case.get("runner")
      evidence = case.get("last_execution")
      if runner != "spec/unified/execute.lua":
        raise ScopeError(f"passing v0.5 case has no exact runner: {identity}")
      if not isinstance(evidence, str) or not evidence:
        raise ScopeError(f"passing v0.5 case has no execution evidence: {identity}")

      executor = executors.get(identity)
      if executor is None:
        raise ScopeError(f"passing v0.5 case has no exact executor: {identity}")
      if executor.get("environment") != case.get("required_environment"):
        raise ScopeError(f"v0.5 executor environment is stale for {identity}")
      exact_unified += 1
      classification = "passed"
    elif status not in {"deferred_unsupported", "excluded_scope"}:
      raise ScopeError(f"unknown conformance status for {identity}: {status}")
    elif identity in TARGET_VERSION_EXCLUSIONS:
      classification = "excluded"
      excluded_by_activity[owner] += 1
    elif owner in TARGET_OWNERS:
      activity = activities[owner]
      if activity["track"] != "v0-5-v0-7-api":
        raise ScopeError(
          f"v0.5 owner is outside the declared track for {identity}: {owner}"
        )
      if activity["status"] == "completed":
        raise ScopeError(f"completed owner {owner} still defers {identity}")
      classification = "planned"
      planned_by_activity[owner] += 1
    else:
      raise ScopeError(f"unaccounted v0.5 case {identity}: {owner}")

    statuses[classification] += 1
    suites[suite][classification] += 1

  missing_target_exclusions = (
    set(TARGET_VERSION_EXCLUSIONS) - seen_target_version_exclusions
  )
  if missing_target_exclusions:
    identity = sorted(missing_target_exclusions)[0]
    raise ScopeError(f"missing v0.5 target-version exclusion: {identity}")

  report = {
    "evidence": {
      "exact_unified_cases": exact_unified,
    },
    "excluded_by_activity": dict(sorted(excluded_by_activity.items())),
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
      "supported": statuses["passed"] + statuses["planned"],
    },
    "target_owners": sorted(TARGET_OWNERS),
    "target_version_exclusions": TARGET_VERSION_EXCLUSIONS,
    "type": "v0.5-change-stream-scope",
  }

  if statuses["planned"]:
    raise ScopeError(
      f"v0.5 conformance still has {statuses['planned']} planned cases"
    )

  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  report = classify(load_cases(), load_activities())
  report["specifications_commit"] = specifications_commit(LEDGER)
  return report


def write() -> None:
  OUTPUT.write_text(
    json.dumps(generate(), indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
  )


def check() -> None:
  expected = generate()
  actual = json.loads(OUTPUT.read_text(encoding="utf-8"))
  if actual != expected:
    raise ScopeError("generated v0.5 scope is stale")


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
  report = generated["summary"]
  exact = ""
  if arguments.execution_report is not None:
    execution = [
      json.loads(path.read_text(encoding="utf-8"))
      for path in arguments.execution_report
    ]
    evidence = validate_execution(
      load_cases(),
      execution,
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
    "v0.5 change-stream scope: "
    f"{report['classified']} classified, {report['passed']} passed, "
    f"{report['planned']} planned, {report['excluded']} excluded{exact}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
