#!/usr/bin/env python3
"""Generate and validate the v0.9 GridFS conformance boundary."""

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
CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
OUTPUT = ROOT / "spec" / "v09" / "scope.json"

TRACK = "v0-9-gridfs"
CLOSURE_OWNER = "CON-009"
IMPLEMENTED_OWNERS = {
  "ADV-002",
  *(f"GFS-{index:03d}" for index in range(1, 15)),
}
TARGET_OWNERS = IMPLEMENTED_OWNERS | {CLOSURE_OWNER}


def _fixture_identities(path: str, count: int) -> set[str]:
  return {f"{path}::test[{index}]" for index in range(1, count + 1)}


GRIDFS_CASES = set().union(
  _fixture_identities("gridfs/tests/delete.json", 5),
  _fixture_identities("gridfs/tests/deleteByName.json", 2),
  _fixture_identities("gridfs/tests/download.json", 11),
  _fixture_identities("gridfs/tests/downloadByName.json", 8),
  _fixture_identities("gridfs/tests/rename.json", 2),
  _fixture_identities("gridfs/tests/renameByName.json", 2),
  _fixture_identities("gridfs/tests/upload-disableMD5.json", 2),
  _fixture_identities("gridfs/tests/upload.json", 7),
)
RETRYABLE_READ_CASES = set().union(
  _fixture_identities(
    "retryable-reads/tests/unified/gridfs-download-serverErrors.json",
    13,
  ),
  _fixture_identities("retryable-reads/tests/unified/gridfs-download.json", 4),
  _fixture_identities(
    "retryable-reads/tests/unified/gridfs-downloadByName-serverErrors.json",
    13,
  ),
  _fixture_identities(
    "retryable-reads/tests/unified/gridfs-downloadByName.json",
    4,
  ),
)
CSOT_CASES = set().union(
  _fixture_identities(
    "client-side-operations-timeout/tests/gridfs-advanced.json",
    6,
  ),
  _fixture_identities(
    "client-side-operations-timeout/tests/gridfs-delete.json",
    4,
  ),
  _fixture_identities(
    "client-side-operations-timeout/tests/gridfs-download.json",
    4,
  ),
  _fixture_identities(
    "client-side-operations-timeout/tests/gridfs-find.json",
    2,
  ),
  _fixture_identities(
    "client-side-operations-timeout/tests/gridfs-upload.json",
    9,
  ),
)
MACHINE_CASES = GRIDFS_CASES | RETRYABLE_READ_CASES | CSOT_CASES
PROSE_REQUIREMENTS = {
  "gridfs/gridfs-spec.md::bucket-configuration": (
    "ADV-002", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::required-indexes-and-empty-files": (
    "GFS-001", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::chunked-upload-streams": (
    "GFS-002", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::upload-abort": (
    "GFS-003", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::readable-stream-upload": (
    "GFS-004", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::download-streams": (
    "GFS-005", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::download-to-stream": (
    "GFS-006", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::filename-revisions": (
    "GFS-007", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::download-to-stream-by-name": (
    "GFS-008", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::delete-by-id": (
    "GFS-009", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::delete-by-name": (
    "GFS-010", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::files-find": (
    "GFS-011", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::rename-by-id": (
    "GFS-012", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::rename-by-name": (
    "GFS-013", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
  "gridfs/gridfs-spec.md::bucket-drop": (
    "GFS-014", "spec/unit/gridfs_spec.lua", "deterministic-runtime"
  ),
}
RATCHETS = {
  "classified": 113,
  "csot_cases": 25,
  "gridfs_cases": 39,
  "passed": 113,
  "prose_requirements": 15,
  "retryable_read_cases": 34,
  "supported": 113,
}


class ScopeError(ValueError):
  """Raised when the v0.9 conformance boundary loses exact evidence."""


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
  return json.loads(ledger_path.read_text(encoding="utf-8"))["cases"]


def load_requirements(catalog_path: Path = CATALOG) -> dict[str, dict[str, Any]]:
  return json.loads(catalog_path.read_text(encoding="utf-8"))["requirements"]


def load_executors(
  executor_path: Path = EXECUTORS,
) -> dict[str, dict[str, Any]]:
  return json.loads(executor_path.read_text(encoding="utf-8"))["tests"]


def load_capability_ratchets(
  capabilities_path: Path = CAPABILITIES,
) -> dict[str, int]:
  return json.loads(capabilities_path.read_text(encoding="utf-8"))["ratchets"]


def _validate_owner(
  identity: str,
  owner: str,
  activities: dict[str, dict[str, str]],
) -> None:
  if owner not in TARGET_OWNERS or owner not in activities:
    raise ScopeError(f"v0.9 evidence has an unaccounted owner: {identity}")

  activity = activities[owner]
  if activity["track"] != TRACK:
    raise ScopeError(f"v0.9 owner is outside the declared track: {identity}")

  allowed = {"in_progress", "completed"} if owner == CLOSURE_OWNER else {"completed"}
  if activity["status"] not in allowed:
    raise ScopeError(f"v0.9 evidence owner is incomplete: {identity}: {owner}")


def _validate_passing(
  identity: str,
  evidence: dict[str, Any],
  activities: dict[str, dict[str, str]],
) -> None:
  owner = evidence.get("activity")
  _validate_owner(identity, owner, activities)

  if evidence.get("status") != "passed":
    raise ScopeError(f"v0.9 evidence remains deferred: {identity}")
  if not evidence.get("last_execution"):
    raise ScopeError(f"v0.9 evidence has no execution command: {identity}")

  runner = evidence.get("runner")
  if not isinstance(runner, str) or runner.startswith("pending:"):
    raise ScopeError(f"v0.9 evidence has no exact runner: {identity}")
  if not (ROOT / runner).is_file():
    raise ScopeError(f"v0.9 evidence runner does not exist: {identity}")


def _is_gridfs_machine_identity(identity: str) -> bool:
  return identity.startswith((
    "gridfs/tests/",
    "retryable-reads/tests/unified/gridfs-",
    "client-side-operations-timeout/tests/gridfs-",
  ))


def validate_execution(
  cases: dict[str, dict[str, Any]],
  report: dict[str, Any] | list[dict[str, Any]],
  expected_ratchets: dict[str, int],
) -> dict[str, int]:
  reports = report if isinstance(report, list) else [report]
  required = {
    identity
    for identity in MACHINE_CASES
    if identity in cases and cases[identity].get("status") == "passed"
  }
  passed = set()

  if required != MACHINE_CASES:
    missing = sorted(MACHINE_CASES - required)
    raise ScopeError(f"v0.9 exact execution target is missing: {missing[0]}")

  for report_index, exact_report in enumerate(reports):
    if not isinstance(exact_report, dict) or exact_report.get("type") != "execution":
      raise ScopeError("v0.9 evidence is not a unified execution report")

    report_ratchets = exact_report.get("ratchets")
    if report_index == 0 and report_ratchets != expected_ratchets:
      raise ScopeError("v0.9 execution report ratchets do not match the manifest")
    if report_index > 0:
      if not isinstance(report_ratchets, dict) \
          or set(report_ratchets) != set(expected_ratchets):
        raise ScopeError("v0.9 supplemental report ratchets are malformed")
      if any(
        not isinstance(value, int) or not 0 <= value <= expected_ratchets[name]
        for name, value in report_ratchets.items()
      ):
        raise ScopeError("v0.9 supplemental report ratchets are malformed")

    rows = exact_report.get("tests")
    if not isinstance(rows, list):
      raise ScopeError("v0.9 execution report test rows must be an array")

    seen = set()
    for row in rows:
      if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        raise ScopeError("v0.9 execution report contains a malformed test row")
      identity = row["id"]
      if identity in seen:
        raise ScopeError(f"v0.9 execution report repeats {identity}")
      seen.add(identity)
      if identity not in required:
        continue
      if row.get("status") == "passed":
        passed.add(identity)
      elif row.get("status") != "environment_skipped":
        detail = row.get("error")
        suffix = f": {detail}" if isinstance(detail, str) and detail else ""
        raise ScopeError(
          f"v0.9 target did not pass exact execution: {identity}{suffix}"
        )

  missing = sorted(required - passed)
  if missing:
    raise ScopeError(f"v0.9 target did not pass exact execution: {missing[0]}")

  return {"passed": len(passed), "required": len(required)}


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  current = {
    "classified": report["summary"]["classified"],
    "csot_cases": report["evidence"]["csot_cases"],
    "gridfs_cases": report["evidence"]["gridfs_cases"],
    "passed": report["summary"]["passed"],
    "prose_requirements": report["evidence"]["prose_requirements"],
    "retryable_read_cases": report["evidence"]["retryable_read_cases"],
    "supported": report["summary"]["supported"],
  }
  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.9 {name} ratchet regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
  executors: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
  executors = load_executors() if executors is None else executors
  discovered = {
    identity for identity in cases if _is_gridfs_machine_identity(identity)
  }
  if discovered != MACHINE_CASES:
    missing = sorted(MACHINE_CASES - discovered)
    stale = sorted(discovered - MACHINE_CASES)
    raise ScopeError(
      f"v0.9 machine identities differ: missing={missing}, stale={stale}"
    )

  prose = {
    identity: requirement
    for identity, requirement in requirements.items()
    if requirement.get("suite") == "gridfs"
  }
  if set(prose) != set(PROSE_REQUIREMENTS):
    missing = sorted(set(PROSE_REQUIREMENTS) - set(prose))
    stale = sorted(set(prose) - set(PROSE_REQUIREMENTS))
    raise ScopeError(
      f"v0.9 prose requirements differ: missing={missing}, stale={stale}"
    )

  selected = {identity: cases[identity] for identity in MACHINE_CASES}
  statuses: Counter[str] = Counter()
  suites: dict[str, Counter[str]] = {}
  passed_by_activity: Counter[str] = Counter()

  for identity, case in sorted(selected.items()):
    _validate_passing(identity, case, activities)
    if case.get("runner") != "spec/unified/execute.lua":
      raise ScopeError(f"v0.9 machine evidence has no exact runner: {identity}")

    executor = executors.get(identity)
    if executor is None:
      raise ScopeError(f"v0.9 machine evidence has no exact executor: {identity}")
    if executor.get("environment") != case.get("required_environment"):
      raise ScopeError(f"v0.9 executor environment is stale for {identity}")

    owner = case["activity"]
    passed_by_activity[owner] += 1
    statuses["passed"] += 1
    suites.setdefault(case["suite"], Counter())["passed"] += 1

  for identity, requirement in sorted(prose.items()):
    _validate_passing(identity, requirement, activities)
    owner, runner, environment = PROSE_REQUIREMENTS[identity]
    if (
      requirement.get("activity") != owner
      or requirement.get("runner") != runner
      or requirement.get("required_environment") != environment
    ):
      raise ScopeError(f"v0.9 prose evidence is stale: {identity}")

    passed_by_activity[owner] += 1
    statuses["passed"] += 1
    suites.setdefault(requirement["suite"], Counter())["passed"] += 1

  for identity, evidence in {**cases, **requirements}.items():
    if (
      evidence.get("activity") in TARGET_OWNERS
      and evidence.get("status") != "passed"
    ):
      raise ScopeError(f"v0.9 activity still owns non-passing evidence: {identity}")

  classified = len(selected) + len(prose)
  report = {
    "evidence": {
      "csot_cases": len(CSOT_CASES),
      "gridfs_cases": len(GRIDFS_CASES),
      "prose_requirements": len(prose),
      "retryable_read_cases": len(RETRYABLE_READ_CASES),
    },
    "machine_cases": dict(sorted(selected.items())),
    "passed_by_activity": dict(sorted(passed_by_activity.items())),
    "prose_requirements": dict(sorted(prose.items())),
    "ratchets": RATCHETS,
    "schema_version": 1,
    "suites": {
      suite: dict(sorted(counts.items()))
      for suite, counts in sorted(suites.items())
    },
    "summary": {
      "classified": classified,
      "passed": statuses["passed"],
      "planned": 0,
      "supported": statuses["passed"],
    },
    "target_owners": sorted(TARGET_OWNERS),
    "type": "v0.9-gridfs-scope",
  }
  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  return classify(
    load_cases(),
    load_requirements(),
    load_activities(),
  )


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  parser.add_argument("--execution-report", action="append", type=Path)
  arguments = parser.parse_args(argv)

  try:
    generated = generate()
    encoded = json.dumps(generated, indent=2, sort_keys=True) + "\n"
    if arguments.check:
      if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
        raise ScopeError("generated v0.9 scope is stale")
    else:
      OUTPUT.write_text(encoded, encoding="utf-8")

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
      )
      exact = f"; exact evidence {evidence['passed']}/{evidence['required']}"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"v0.9 scope: {exc}")
    return 2

  summary = generated["summary"]
  print(
    f"v0.9 GridFS scope: {summary['classified']} classified, "
    f"{summary['passed']} passed{exact}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
