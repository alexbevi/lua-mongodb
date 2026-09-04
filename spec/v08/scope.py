#!/usr/bin/env python3
"""Generate and validate the v0.8 wire-compression conformance boundary."""

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
OUTPUT = ROOT / "spec" / "v08" / "scope.json"

TRACK = "v0-8-wire-compression"
CLOSURE_OWNER = "CON-008"
TARGET_OWNERS = {
  "ADV-004",
  *(f"WIRE-{index:03d}" for index in range(2, 10)),
  CLOSURE_OWNER,
}
CONFIGURATION_CASES = {
  f"uri-options/tests/compression-options.json::test[{index}]"
  for index in range(1, 6)
}
PROSE_REQUIREMENTS = {
  "compression/OP_COMPRESSED.md::client-options": (
    "ADV-004", "spec/support/config_runner.lua", "none"
  ),
  "compression/OP_COMPRESSED.md::framing-and-malformed-messages": (
    "WIRE-003", "spec/unit/op_compressed_spec.lua", "none"
  ),
  "compression/OP_COMPRESSED.md::handshake-and-negotiation": (
    "WIRE-005", "spec/unit/command_executor_spec.lua", "deterministic-runtime"
  ),
  "compression/OP_COMPRESSED.md::prohibited-commands": (
    "WIRE-006", "spec/unit/command_executor_spec.lua", "deterministic-runtime"
  ),
  "compression/OP_COMPRESSED.md::response-decompression": (
    "WIRE-004", "spec/unit/op_compressed_spec.lua", "none"
  ),
  "compression/OP_COMPRESSED.md::sharded-round-trip": (
    CLOSURE_OWNER, "spec/compatibility/sharded_probe.lua", "live-sharded"
  ),
  "compression/OP_COMPRESSED.md::snappy-codec": (
    "WIRE-008", "spec/unit/snappy_runtime_spec.lua", "none"
  ),
  "compression/OP_COMPRESSED.md::standalone-round-trips": (
    CLOSURE_OWNER, "spec/compatibility/probe.lua", "live-mongodb"
  ),
  "compression/OP_COMPRESSED.md::unavailable-codec-warnings": (
    "WIRE-009", "spec/integration/client_api_spec.lua", "loopback-tcp"
  ),
  "compression/OP_COMPRESSED.md::zlib-codec": (
    "WIRE-002", "spec/unit/zlib_runtime_spec.lua", "none"
  ),
  "compression/OP_COMPRESSED.md::zstandard-codec": (
    "WIRE-009", "spec/unit/zstandard_runtime_spec.lua", "none"
  ),
}
RATCHETS = {
  "classified": 16,
  "configuration_cases": 5,
  "passed": 16,
  "prose_requirements": 11,
  "supported": 16,
}


class ScopeError(ValueError):
  """Raised when the v0.8 conformance boundary loses exact evidence."""


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


def _validate_owner(
  identity: str,
  owner: str,
  activities: dict[str, dict[str, str]],
) -> None:
  if owner not in TARGET_OWNERS or owner not in activities:
    raise ScopeError(f"v0.8 evidence has an unaccounted owner: {identity}")

  activity = activities[owner]
  if activity["track"] != TRACK:
    raise ScopeError(f"v0.8 owner is outside the declared track: {identity}")

  allowed = {"in_progress", "completed"} if owner == CLOSURE_OWNER else {"completed"}
  if activity["status"] not in allowed:
    raise ScopeError(f"v0.8 evidence owner is incomplete: {identity}: {owner}")


def _validate_passing(
  identity: str,
  evidence: dict[str, Any],
  activities: dict[str, dict[str, str]],
) -> None:
  owner = evidence.get("activity")
  _validate_owner(identity, owner, activities)

  if evidence.get("status") != "passed":
    raise ScopeError(f"v0.8 evidence remains deferred: {identity}")
  if not evidence.get("last_execution"):
    raise ScopeError(f"v0.8 evidence has no execution command: {identity}")

  runner = evidence.get("runner")
  if not isinstance(runner, str) or runner.startswith("pending:"):
    raise ScopeError(f"v0.8 evidence has no exact runner: {identity}")
  if not (ROOT / runner).is_file():
    raise ScopeError(f"v0.8 evidence runner does not exist: {identity}")


def validate_scope_ratchets(report: dict[str, Any]) -> None:
  current = {
    "classified": report["summary"]["classified"],
    "configuration_cases": report["evidence"]["configuration_cases"],
    "passed": report["summary"]["passed"],
    "prose_requirements": report["evidence"]["prose_requirements"],
    "supported": report["summary"]["supported"],
  }
  for name, minimum in RATCHETS.items():
    if current[name] < minimum:
      raise ScopeError(
        f"v0.8 {name} ratchet regressed from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  configuration = {
    identity: cases[identity]
    for identity in CONFIGURATION_CASES
    if identity in cases
  }
  prose = {
    identity: requirement
    for identity, requirement in requirements.items()
    if requirement.get("suite") == "compression"
  }

  if set(configuration) != CONFIGURATION_CASES:
    missing = sorted(CONFIGURATION_CASES - set(configuration))
    raise ScopeError(f"v0.8 configuration cases are missing: {missing}")
  if set(prose) != set(PROSE_REQUIREMENTS):
    missing = sorted(set(PROSE_REQUIREMENTS) - set(prose))
    stale = sorted(set(prose) - set(PROSE_REQUIREMENTS))
    raise ScopeError(
      f"v0.8 prose requirements differ: missing={missing}, stale={stale}"
    )

  statuses: Counter[str] = Counter()
  suites: dict[str, Counter[str]] = {}

  for identity, case in sorted(configuration.items()):
    _validate_passing(identity, case, activities)
    if (
      case.get("activity") != "ADV-004"
      or case.get("runner") != "spec/support/config_runner.lua"
      or case.get("required_environment") != "none"
    ):
      raise ScopeError(f"v0.8 configuration evidence is stale: {identity}")
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
      raise ScopeError(f"v0.8 prose evidence is stale: {identity}")
    statuses["passed"] += 1
    suites.setdefault(requirement["suite"], Counter())["passed"] += 1

  for identity, evidence in {**cases, **requirements}.items():
    owner = evidence.get("activity")
    if owner in TARGET_OWNERS and evidence.get("status") == "deferred_unsupported":
      raise ScopeError(f"v0.8 activity still owns deferred evidence: {identity}")

  report = {
    "configuration_cases": dict(sorted(configuration.items())),
    "evidence": {
      "configuration_cases": len(configuration),
      "prose_requirements": len(prose),
    },
    "prose_requirements": dict(sorted(prose.items())),
    "ratchets": RATCHETS,
    "schema_version": 1,
    "suites": {
      suite: dict(sorted(counts.items()))
      for suite, counts in sorted(suites.items())
    },
    "summary": {
      "classified": len(configuration) + len(prose),
      "passed": statuses["passed"],
      "planned": 0,
      "supported": statuses["passed"],
    },
    "target_owners": sorted(TARGET_OWNERS),
    "type": "v0.8-wire-compression-scope",
  }
  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  report = classify(load_cases(), load_requirements(), load_activities())
  report["specifications_commit"] = specifications_commit(LEDGER)
  return report


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"v0.8 scope: {exc}")
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("v0.8 scope report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  print(
    f"v0.8 scope: {report['summary']['passed']} passing requirements, "
    "0 planned"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
