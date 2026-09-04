#!/usr/bin/env python3
"""Generate and validate the v0.10 load-balancing conformance boundary."""

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
CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
OUTPUT = ROOT / "spec" / "v10" / "scope.json"

TRACK = "v0-10-load-balancing"
CLOSURE_OWNER = "CON-010"
RELEASE_OWNER = "REL-059"
OPTIONAL_OWNERS = {
  "ADV-010",
  "CMAP-005",
  "CMAP-006",
  "CON-017",
  "LOG-002",
  "LOG-003",
  "LOG-004",
  "LOG-005",
  "LOG-006",
  "LOG-007",
  "LOG-010",
  "LOG-011",
  "LOG-012",
  "LOG-013",
  "LOG-014",
  "LOG-015",
  "LOG-016",
  "LOG-017",
  "LOG-018",
  "LOG-019",
  "LOG-020",
  "LOG-021",
  "LOG-022",
  "LOG-023",
  "LOG-024",
  "LOG-025",
  "LOG-026",
  "OTEL-002",
  "OTEL-003",
  "OTEL-004",
  "SDAM-009",
  "SDAM-010",
  "SEL-002",
  "SEL-003",
}
LEGACY_EXCLUSION_OWNER = "REL-053"
UPSTREAM_SKIP = (
  "load-balancers/tests/lb-connection-establishment.json::test[1]"
)
TERMINAL_UNSUPPORTED = {
  "ocsp-support/ocsp-support.md::document": "TLS-002",
  "socks5-support/socks5.md::document": "ADV-012",
}
CLOSURE_EXECUTORS = {
  "run-command/tests/unified/runCursorCommand.json::test[5]",
  "run-command/tests/unified/runCursorCommand.json::test[6]",
  "server-discovery-and-monitoring/tests/unified/"
    "loadbalanced-emit-topology-changed-before-close.json::test[1]",
}
TARGET_VERSION_EXECUTION_EXCLUSIONS = frozenset({
  "crud/tests/unified/aggregate-write-readPreference.json::test[2]",
  "crud/tests/unified/aggregate-write-readPreference.json::test[4]",
  "retryable-writes/tests/unified/insertOne-serverErrors.json::test[2]",
  "retryable-writes/tests/unified/insertOne-serverErrors.json::test[3]",
  "retryable-writes/tests/unified/insertOne-serverErrors.json::test[4]",
})
RATCHETS = {
  "classified": 1044,
  "dedicated_cases": 40,
  "exact_unified_cases": 741,
  "excluded": 18,
  "out_of_track": 235,
  "passed": 780,
  "run_on_branches": 1002,
  "unsupported": 11,
}


class ScopeError(ValueError):
  """Raised when the v0.10 conformance boundary loses exact evidence."""


def load_json(path: Path) -> dict[str, Any]:
  return json.loads(path.read_text(encoding="utf-8"))


def load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  plan = load_json(plan_path)
  progress = load_json(progress_path)["activities"]
  return {
    activity["id"]: {
      "status": progress.get(activity["id"], {}).get("status", "pending"),
      "track": activity.get("track", ""),
    }
    for activity in plan["activities"]
  }


def load_cases(path: Path = LEDGER) -> dict[str, dict[str, Any]]:
  return load_json(path)["cases"]


def load_requirements(path: Path = CATALOG) -> dict[str, dict[str, Any]]:
  return load_json(path)["requirements"]


def load_capabilities(path: Path = CAPABILITIES) -> dict[str, dict[str, Any]]:
  return load_json(path)["tests"]


def load_capability_ratchets(path: Path = CAPABILITIES) -> dict[str, int]:
  return load_json(path)["ratchets"]


def load_executors(path: Path = EXECUTORS) -> dict[str, dict[str, Any]]:
  return load_json(path)["tests"]


def _is_load_balanced_branch(capability: dict[str, Any]) -> bool:
  requirements = capability.get("requirements", {})
  return "load-balanced" in requirements.get("topologies", [])


def _require_activity(
  identity: str,
  owner: str,
  activities: dict[str, dict[str, str]],
  *,
  closure_allowed: bool = False,
  in_progress_allowed: bool = False,
) -> None:
  activity = activities.get(owner)

  if activity is None:
    raise ScopeError(f"v0.10 evidence has an unknown owner: {identity}: {owner}")

  allowed = {"completed"}
  if in_progress_allowed:
    allowed.add("in_progress")

  if closure_allowed and owner == CLOSURE_OWNER:
    allowed.add("in_progress")

  if activity["status"] not in allowed:
    raise ScopeError(f"v0.10 evidence owner is incomplete: {identity}: {owner}")


def _require_execution(identity: str, evidence: dict[str, Any]) -> None:
  runner = evidence.get("runner")

  if not isinstance(runner, str) or runner.startswith(("none:", "pending:")):
    raise ScopeError(f"v0.10 evidence has no exact runner: {identity}")

  if not (ROOT / runner).is_file():
    raise ScopeError(f"v0.10 evidence runner does not exist: {identity}")

  if not evidence.get("last_execution"):
    raise ScopeError(f"v0.10 evidence has no execution command: {identity}")


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  current = {
    "classified": report["summary"]["classified"],
    "dedicated_cases": report["evidence"]["dedicated_cases"],
    "exact_unified_cases": report["evidence"]["exact_unified_cases"],
    "excluded": report["summary"]["excluded"],
    "out_of_track": report["summary"]["planned"],
    "passed": report["summary"]["passed"],
    "run_on_branches": report["evidence"]["run_on_branches"],
    "unsupported": report["summary"]["unsupported"],
  }

  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.10 {name} count regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  capabilities: dict[str, dict[str, Any]],
  executors: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  track_owners = {
    owner
    for owner, activity in activities.items()
    if activity["track"] == TRACK and owner != RELEASE_OWNER
  }
  dedicated = {
    identity: evidence
    for identity, evidence in cases.items()
    if evidence.get("suite") == "load-balancers"
  }
  branches = {
    identity: capability
    for identity, capability in capabilities.items()
    if _is_load_balanced_branch(capability)
  }

  if len(dedicated) != RATCHETS["dedicated_cases"]:
    raise ScopeError("v0.10 dedicated load-balancer identity count changed")

  if len(branches) != RATCHETS["run_on_branches"]:
    raise ScopeError("v0.10 load-balanced runOn identity count changed")

  statuses: Counter[str] = Counter()
  passed_by_activity: Counter[str] = Counter()

  for identity, evidence in sorted(dedicated.items()):
    owner = evidence.get("activity")

    if owner not in track_owners:
      raise ScopeError(f"v0.10 dedicated case has an out-of-track owner: {identity}")

    _require_activity(identity, owner, activities)
    _require_execution(identity, evidence)

    if identity == UPSTREAM_SKIP:
      if (
        evidence.get("status") != "excluded_scope"
        or evidence.get("required_environment") != "none"
        or "skipReason" not in evidence.get("reason", "")
      ):
        raise ScopeError(f"v0.10 upstream skip classification is stale: {identity}")

      statuses["excluded"] += 1
      continue

    if evidence.get("status") != "passed":
      raise ScopeError(f"v0.10 dedicated case remains deferred: {identity}")

    statuses["passed"] += 1
    passed_by_activity[owner] += 1

  exact_unified = set()
  terminal = {}

  for identity, capability in sorted(branches.items()):
    status = capability.get("status")
    owner = capability.get("activity")

    if owner in track_owners and status != "runnable":
      raise ScopeError(f"v0.10 activity still owns a deferred branch: {identity}")

    if status == "runnable":
      _require_activity(identity, owner, activities, closure_allowed=True)
      executor = executors.get(identity)
      evidence = cases.get(identity)

      if executor is None or executor.get("activity") != owner:
        raise ScopeError(f"v0.10 branch has no exact executor: {identity}")

      if (
        evidence is None
        or evidence.get("status") != "passed"
        or evidence.get("runner") != "spec/unified/execute.lua"
        or evidence.get("required_environment") != executor.get("environment")
      ):
        raise ScopeError(f"v0.10 branch has stale passing evidence: {identity}")

      _require_execution(identity, evidence)
      exact_unified.add(identity)
      statuses["passed"] += 1
      passed_by_activity[owner] += 1
    elif status == "deferred_unsupported":
      activity = activities.get(owner)

      if (
        owner not in OPTIONAL_OWNERS
        or activity is None
        or activity["track"] == TRACK
        or activity["status"] == "completed"
        or not capability.get("reason")
      ):
        raise ScopeError(f"v0.10 branch has no optional-suite owner: {identity}")

      statuses["planned"] += 1
    elif status == "unsupported":
      evidence = cases.get(identity)

      if (
        evidence is None
        or evidence.get("activity") != owner
        or evidence.get("status") != "unsupported"
        or evidence.get("runner") != "none:unsupported"
        or evidence.get("required_environment") != "none"
        or evidence.get("last_execution") is not None
        or not capability.get("reason")
        or not evidence.get("reason")
      ):
        raise ScopeError(f"v0.10 terminal unsupported evidence is stale: {identity}")

      _require_activity(identity, owner, activities, in_progress_allowed=True)
      terminal[identity] = evidence
      statuses["unsupported"] += 1
    elif status == "excluded_scope":
      if owner != LEGACY_EXCLUSION_OWNER or not capability.get("reason"):
        raise ScopeError(f"v0.10 branch has a stale exclusion: {identity}")

      _require_activity(identity, owner, activities)
      statuses["excluded"] += 1
    else:
      raise ScopeError(f"v0.10 branch has an invalid status: {identity}: {status}")

  if CLOSURE_EXECUTORS - exact_unified:
    raise ScopeError("v0.10 closure executor inventory is incomplete")

  if TARGET_VERSION_EXECUTION_EXCLUSIONS - exact_unified:
    raise ScopeError("v0.10 target-version exclusion inventory is stale")

  for identity in CLOSURE_EXECUTORS:
    if executors[identity].get("environment") != "live-load-balanced":
      raise ScopeError(f"v0.10 closure executor environment is stale: {identity}")

  for identity, owner in TERMINAL_UNSUPPORTED.items():
    evidence = requirements.get(identity)

    if (
      evidence is None
      or evidence.get("activity") != owner
      or evidence.get("status") != "unsupported"
      or evidence.get("runner") != "none:unsupported"
      or evidence.get("required_environment") != "none"
      or evidence.get("last_execution") is not None
      or not evidence.get("reason")
    ):
      raise ScopeError(f"v0.10 terminal unsupported evidence is stale: {identity}")

    _require_activity(identity, owner, activities)
    terminal[identity] = evidence
    statuses["unsupported"] += 1

  classified = len(dedicated) + len(branches) + len(TERMINAL_UNSUPPORTED)
  report = {
    "dedicated_cases": dict(sorted(dedicated.items())),
    "evidence": {
      "dedicated_cases": len(dedicated),
      "exact_unified_cases": len(exact_unified),
      "run_on_branches": len(branches),
      "terminal_unsupported": len(terminal),
    },
    "exact_unified_cases": sorted(exact_unified),
    "passed_by_activity": dict(sorted(passed_by_activity.items())),
    "ratchets": RATCHETS,
    "run_on_branches": dict(sorted(branches.items())),
    "schema_version": 1,
    "summary": {
      "classified": classified,
      "excluded": statuses["excluded"],
      "passed": statuses["passed"],
      "planned": statuses["planned"],
      "supported": statuses["passed"],
      "unsupported": statuses["unsupported"],
    },
    "terminal_unsupported": dict(sorted(terminal.items())),
    "track_owners": sorted(track_owners),
    "type": "v0.10-load-balancing-scope",
  }
  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  report = classify(
    load_cases(),
    load_requirements(),
    load_capabilities(),
    load_executors(),
    load_activities(),
  )
  report["specifications_commit"] = specifications_commit(LEDGER)
  return report


def validate_execution(
  report: dict[str, Any] | list[dict[str, Any]],
  expected_ratchets: dict[str, int],
) -> dict[str, int]:
  reports = report if isinstance(report, list) else [report]
  required = (
    set(generate()["exact_unified_cases"])
    - TARGET_VERSION_EXECUTION_EXCLUSIONS
  )
  passed = set()

  for report_index, exact_report in enumerate(reports):
    if exact_report.get("type") != "execution":
      raise ScopeError("v0.10 evidence is not a unified execution report")

    ratchets = exact_report.get("ratchets")

    if report_index == 0 and ratchets != expected_ratchets:
      raise ScopeError("v0.10 execution report limits do not match the manifest")

    rows = exact_report.get("tests")

    if not isinstance(rows, list):
      raise ScopeError("v0.10 execution report test rows must be an array")

    seen = set()

    for row in rows:
      identity = row.get("id") if isinstance(row, dict) else None

      if not isinstance(identity, str):
        raise ScopeError("v0.10 execution report has a malformed row")

      if identity in seen:
        raise ScopeError(f"v0.10 execution report repeats {identity}")

      seen.add(identity)

      if identity not in required:
        continue

      if row.get("status") == "passed":
        passed.add(identity)
      elif row.get("status") != "environment_skipped":
        detail = row.get("error")
        suffix = f": {detail}" if isinstance(detail, str) and detail else ""
        raise ScopeError(f"v0.10 target did not pass: {identity}{suffix}")

  missing = sorted(required - passed)

  if missing:
    raise ScopeError(f"v0.10 target did not pass: {missing[0]}")

  return {"passed": len(passed), "required": len(required)}


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
        raise ScopeError("generated v0.10 scope is stale")
    else:
      OUTPUT.write_text(encoded, encoding="utf-8")

    exact = ""

    if arguments.execution_report:
      reports = [load_json(path) for path in arguments.execution_report]
      evidence = validate_execution(reports, load_capability_ratchets())
      exact = f"; exact evidence {evidence['passed']}/{evidence['required']}"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"v0.10 scope: {exc}")
    return 2

  summary = generated["summary"]
  print(
    f"v0.10 load-balancing scope: {summary['classified']} classified, "
    f"{summary['passed']} passed, {summary['planned']} optional, "
    f"{summary['unsupported']} unsupported{exact}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
