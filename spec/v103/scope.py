#!/usr/bin/env python3
"""Generate and validate the v0.10.3 logging-foundation boundary."""

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
OUTPUT = ROOT / "spec" / "v103" / "scope.json"

TRACK = "v0-10-3-logging-foundation"
CLOSURE_OWNER = "CON-014"
RELEASE_OWNER = "REL-062"
TRACK_ORDER = [
  "ADV-009",
  "LOG-008",
  "LOG-009",
  "LOG-001",
  CLOSURE_OWNER,
  RELEASE_OWNER,
]
FOUNDATION_REQUIREMENTS = {
  "logging/logging.md::configuration": (
    "ADV-009", "spec/unit/logging_spec.lua", "deterministic-runtime"
  ),
  "logging/logging.md::destination": (
    "ADV-009", "spec/unit/logging_spec.lua", "deterministic-runtime"
  ),
  "logging/logging.md::structured-events": (
    "LOG-008", "spec/unit/logging_spec.lua", "deterministic-runtime"
  ),
  "unified-test-format/unified-test-format.md::expected-log-messages": (
    "LOG-001", "spec/unit/unified_logs_spec.lua", "deterministic-runtime"
  ),
}
STANDARDIZED_REQUIREMENT = "logging/logging.md::standardized-components"
STANDARDIZED_REQUIREMENT_OWNER = "CON-017"
PLANNED_OWNER_COUNTS = {
  "BP-001": 6,
  "BP-004": 28,
  "BP-005": 27,
  "BP-006": 45,
  "BP-007": 3,
  "BP-008": 9,
  "BP-009": 5,
  "CMAP-005": 2,
  "CMAP-006": 5,
  "LOG-002": 5,
  "LOG-003": 16,
  "LOG-004": 2,
  "LOG-005": 1,
  "LOG-006": 2,
  "LOG-007": 1,
  "LOG-010": 1,
  "LOG-011": 1,
  "LOG-012": 1,
  "LOG-013": 2,
  "LOG-014": 2,
  "LOG-015": 3,
  "LOG-016": 2,
  "LOG-017": 1,
  "LOG-018": 1,
  "LOG-019": 2,
  "LOG-020": 2,
  "LOG-021": 2,
  "LOG-022": 3,
  "LOG-023": 2,
  "LOG-024": 1,
  "LOG-025": 1,
  "LOG-026": 1,
  "OTEL-002": 9,
  "OTEL-003": 12,
  "OTEL-004": 3,
  "SDAM-009": 4,
  "SDAM-010": 6,
  "SEL-002": 7,
  "SEL-003": 4,
}
PLANNED_OWNERS = frozenset(PLANNED_OWNER_COUNTS)
FOUNDATION_OWNERS = frozenset(
  owner for owner, _, _ in FOUNDATION_REQUIREMENTS.values()
)
RATCHETS = {
  "classified": 234,
  "foundation_requirements": 4,
  "planned": 230,
  "standardized_logging_cases": 93,
  "standardized_logging_requirements": 5,
  "supported": 4,
  "unified_cases": 24,
}
COMMAND_SUITE = "command-logging-and-monitoring"
SERVER_SELECTION_LOGGING_PREFIX = "server-selection/tests/logging/"
SDAM_LOGGING_PREFIX = "server-discovery-and-monitoring/tests/unified/logging-"
CMAP_LOGGING_PREFIX = "connection-monitoring-and-pooling/tests/logging/"
COMMAND_EXCLUSIONS = {
  "command-logging-and-monitoring/tests/monitoring/find.json::test[5]": (
    "the server requirement capped at MongoDB 4.4.99 is below the MongoDB 7.0 "
    "production-core floor"
  ),
  "command-logging-and-monitoring/tests/monitoring/redacted-commands.json::test[4]": (
    "getnonce is capped below MongoDB 7.0 and is outside production-core v1"
  ),
}


class ScopeError(ValueError):
  """Raised when the logging foundation loses exact ownership or evidence."""


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


def load_capabilities(
  capabilities_path: Path = CAPABILITIES,
) -> dict[str, dict[str, Any]]:
  return json.loads(capabilities_path.read_text(encoding="utf-8"))["tests"]


def _validate_track(activities: dict[str, dict[str, str]]) -> None:
  actual = [
    activity_id
    for activity_id, activity in activities.items()
    if activity["track"] == TRACK
  ]
  if actual != TRACK_ORDER:
    raise ScopeError("v0.10.3 logging-foundation track inventory changed")


def _validate_foundation(
  identity: str,
  requirement: dict[str, Any],
  activities: dict[str, dict[str, str]],
) -> None:
  expected = FOUNDATION_REQUIREMENTS[identity]
  actual = (
    requirement.get("activity"),
    requirement.get("runner"),
    requirement.get("required_environment"),
  )
  if actual != expected:
    raise ScopeError(f"v0.10.3 logging evidence is stale: {identity}")

  owner, runner, _ = expected
  activity = activities.get(owner)
  if not activity or activity["track"] != TRACK or activity["status"] != "completed":
    raise ScopeError(f"v0.10.3 logging evidence owner is incomplete: {identity}")
  if requirement.get("status") != "passed" or not requirement.get("last_execution"):
    raise ScopeError(f"v0.10.3 logging evidence is not passing: {identity}")
  if runner.startswith(("none:", "pending:")) or not (ROOT / runner).is_file():
    raise ScopeError(f"v0.10.3 logging evidence has no exact runner: {identity}")


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  standardized = report["standardized_logging_conformance"]
  current = {
    "classified": report["summary"]["classified"],
    "foundation_requirements": report["evidence"]["foundation_requirements"],
    "planned": report["summary"]["planned"],
    "standardized_logging_cases": standardized["cases"],
    "standardized_logging_requirements": standardized["requirements"],
    "supported": report["summary"]["supported"],
    "unified_cases": report["evidence"]["unified_cases"],
  }
  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.10.3 logging {name} ratchet regressed "
        f"from {minimum} to {current[name]}"
      )


def command_conformance(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  command_cases = {
    identity: case
    for identity, case in cases.items()
    if case.get("suite") == COMMAND_SUITE
  }
  exclusions = {
    identity: case.get("reason")
    for identity, case in command_cases.items()
    if case.get("status") == "excluded_scope"
  }
  if exclusions != COMMAND_EXCLUSIONS:
    raise ScopeError("command logging scope exclusions changed")

  for identity, case in sorted(command_cases.items()):
    status = case.get("status")
    if status not in {"passed", "excluded_scope"}:
      raise ScopeError(f"command logging case is not closed: {identity}")
    if status == "passed" and (
      not case.get("last_execution")
      or str(case.get("runner", "")).startswith(("none:", "pending:"))
    ):
      raise ScopeError(f"command logging case lacks exact evidence: {identity}")

    owner = case.get("activity")
    if str(owner).startswith("LOG-"):
      activity = activities.get(owner)
      if not activity or activity.get("status") != "completed":
        raise ScopeError(f"command logging owner is incomplete: {identity}")

  return {
    "cases": len(command_cases),
    "statuses": dict(sorted(Counter(
      case["status"] for case in command_cases.values()
    ).items())),
  }


def server_selection_conformance(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  selection_cases = {
    identity: case
    for identity, case in cases.items()
    if identity.startswith(SERVER_SELECTION_LOGGING_PREFIX)
  }

  for identity, case in sorted(selection_cases.items()):
    if case.get("status") != "passed":
      raise ScopeError(f"server selection logging case is not closed: {identity}")
    if not case.get("last_execution") or str(case.get("runner", "")).startswith(
      ("none:", "pending:")
    ):
      raise ScopeError(f"server selection logging case lacks exact evidence: {identity}")

    owner = case.get("activity")
    activity = activities.get(owner)
    if (
      owner not in {"SEL-002", "SEL-003"}
      or not activity
      or activity.get("status") != "completed"
    ):
      raise ScopeError(f"server selection logging owner is incomplete: {identity}")

  return {
    "cases": len(selection_cases),
    "statuses": dict(sorted(Counter(
      case["status"] for case in selection_cases.values()
    ).items())),
  }


def standardized_logging_conformance(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  capabilities: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  requirement_ids = set(FOUNDATION_REQUIREMENTS) | {STANDARDIZED_REQUIREMENT}
  logging_requirements = {
    identity: requirement
    for identity, requirement in requirements.items()
    if identity in requirement_ids
  }
  if set(logging_requirements) != requirement_ids:
    missing = sorted(requirement_ids - set(logging_requirements))
    raise ScopeError(f"standardized logging prose requirement is missing: {missing}")

  component_requirement = logging_requirements[STANDARDIZED_REQUIREMENT]
  if (
    component_requirement.get("activity") != STANDARDIZED_REQUIREMENT_OWNER
    or component_requirement.get("status") != "passed"
    or component_requirement.get("runner") != "spec/v103/scope.py"
    or not component_requirement.get("last_execution")
  ):
    raise ScopeError("standardized logging prose evidence is stale")
  owner = activities.get(STANDARDIZED_REQUIREMENT_OWNER)
  if not owner or owner.get("status") not in {"in_progress", "completed"}:
    raise ScopeError("standardized logging prose owner is inactive")

  logging_cases = {
    identity: case
    for identity, case in cases.items()
    if case.get("suite") == COMMAND_SUITE
    or identity.startswith(SERVER_SELECTION_LOGGING_PREFIX)
    or identity.startswith(SDAM_LOGGING_PREFIX)
    or identity.startswith(CMAP_LOGGING_PREFIX)
  }
  expected_unsupported = {
    f"{CMAP_LOGGING_PREFIX}connection-pool-options.json::test[4]": "waitQueueSize",
    f"{CMAP_LOGGING_PREFIX}connection-pool-options.json::test[5]": (
      "waitQueueMultiple"
    ),
  }
  unsupported = {
    identity: case
    for identity, case in logging_cases.items()
    if case.get("status") == "unsupported"
  }
  if set(unsupported) != set(expected_unsupported):
    raise ScopeError("standardized logging unsupported cases changed")

  exclusions = {
    identity: case.get("reason")
    for identity, case in logging_cases.items()
    if case.get("status") == "excluded_scope"
  }
  if exclusions != COMMAND_EXCLUSIONS:
    raise ScopeError("standardized logging exclusions changed")

  capability_statuses = {
    "excluded_scope": "excluded_scope",
    "passed": "runnable",
    "unsupported": "unsupported",
  }
  for identity, case in sorted(logging_cases.items()):
    status = case.get("status")
    if status not in capability_statuses:
      raise ScopeError(f"standardized logging case is not closed: {identity}")
    capability = capabilities.get(identity)
    if (
      not capability
      or capability.get("activity") != case.get("activity")
      or capability.get("status") != capability_statuses[status]
    ):
      raise ScopeError(f"standardized logging capability is stale: {identity}")

    activity = activities.get(case.get("activity"))
    if not activity or activity.get("status") != "completed":
      raise ScopeError(f"standardized logging owner is incomplete: {identity}")

    if status == "passed" and (
      not case.get("last_execution")
      or str(case.get("runner", "")).startswith(("none:", "pending:"))
    ):
      raise ScopeError(f"standardized logging case lacks exact evidence: {identity}")
    if status == "unsupported":
      option = expected_unsupported[identity]
      if (
        case.get("runner") != "none:unsupported"
        or case.get("last_execution") is not None
        or option not in str(case.get("reason", ""))
      ):
        raise ScopeError(f"standardized logging unsupported evidence is stale: {identity}")

  return {
    "cases": len(logging_cases),
    "requirements": len(logging_requirements),
    "requirement_statuses": dict(sorted(Counter(
      requirement["status"] for requirement in logging_requirements.values()
    ).items())),
    "statuses": dict(sorted(Counter(
      case["status"] for case in logging_cases.values()
    ).items())),
  }


def classify(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  capabilities: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  _validate_track(activities)
  foundation = {
    identity: requirements[identity]
    for identity in FOUNDATION_REQUIREMENTS
    if identity in requirements
  }
  if set(foundation) != set(FOUNDATION_REQUIREMENTS):
    missing = sorted(set(FOUNDATION_REQUIREMENTS) - set(foundation))
    raise ScopeError(f"v0.10.3 logging requirements are missing: {missing}")

  for identity, requirement in sorted(foundation.items()):
    _validate_foundation(identity, requirement, activities)

  candidates = {
    identity: case
    for identity, case in cases.items()
    if case.get("activity") in PLANNED_OWNERS | {"ADV-009"}
  }
  for identity, case in sorted(candidates.items()):
    owner = case.get("activity")
    if owner not in PLANNED_OWNERS:
      raise ScopeError(f"standardized observability case has umbrella owner: {identity}")
    if owner not in activities:
      raise ScopeError(f"standardized observability case has unknown owner: {identity}")

  owners = Counter(case["activity"] for case in candidates.values())
  actual_counts = {
    owner: owners[owner]
    for owner in sorted(PLANNED_OWNER_COUNTS)
  }
  if actual_counts != PLANNED_OWNER_COUNTS:
    raise ScopeError(
      "v0.10.3 standardized observability ownership changed: "
      f"expected={PLANNED_OWNER_COUNTS}, actual={actual_counts}"
    )

  standardized = {
    identity: case["activity"]
    for identity, case in sorted(candidates.items())
  }
  capability_cases = {
    identity: capabilities[identity]["activity"]
    for identity in standardized
    if identity in capabilities
  }
  for identity, owner in capability_cases.items():
    if owner != standardized[identity]:
      raise ScopeError(f"unified capability owner differs from ledger: {identity}")
  if any(test.get("activity") == "ADV-009" for test in capabilities.values()):
    raise ScopeError("unified capability inventory retains ADV-009 ownership")

  planned_by_suite = Counter(case["suite"] for case in candidates.values())
  report = {
    "capability_cases": dict(sorted(capability_cases.items())),
    "command_conformance": command_conformance(cases, activities),
    "evidence": {
      "foundation_requirements": len(foundation),
      "standardized_cases": len(standardized),
      "unified_cases": len(capability_cases),
    },
    "foundation_requirements": dict(sorted(foundation.items())),
    "planned_by_activity": actual_counts,
    "planned_by_suite": dict(sorted(planned_by_suite.items())),
    "ratchets": RATCHETS,
    "schema_version": 1,
    "server_selection_conformance": server_selection_conformance(
      cases,
      activities,
    ),
    "standardized_logging_conformance": standardized_logging_conformance(
      cases,
      requirements,
      capabilities,
      activities,
    ),
    "standardized_cases": standardized,
    "summary": {
      "classified": len(foundation) + len(standardized),
      "passed": len(foundation),
      "planned": len(standardized),
      "supported": len(foundation),
    },
    "target_owners": sorted(
      FOUNDATION_OWNERS | PLANNED_OWNERS | {STANDARDIZED_REQUIREMENT_OWNER}
    ),
    "type": "v0.10.3-logging-foundation-scope",
  }
  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  return classify(
    load_cases(),
    load_requirements(),
    load_capabilities(),
    load_activities(),
  )


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"v0.10.3 logging scope: {exc}")
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("v0.10.3 logging scope report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  print(
    f"v0.10.3 logging scope: {report['summary']['passed']} passing "
    f"foundation requirements, {report['summary']['planned']} assigned cases"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
