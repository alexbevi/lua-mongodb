#!/usr/bin/env python3
"""Generate and validate the v0.10.2 GSSAPI conformance boundary."""

from __future__ import annotations

from collections import Counter
import argparse
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
OUTPUT = ROOT / "spec" / "v102" / "scope.json"

TRACK = "v0-10-2-gssapi"
CLOSURE_OWNER = "CON-013"
RELEASE_OWNER = "REL-061"
IMPLEMENTATION_OWNERS = {
  "AUTH-019",
  *(f"AUTH-{index:03d}" for index in range(31, 41)),
}
TARGET_OWNERS = {*IMPLEMENTATION_OWNERS, CLOSURE_OWNER}
TRACK_ORDER = [
  "AUTH-019",
  *(f"AUTH-{index:03d}" for index in range(31, 41)),
  CLOSURE_OWNER,
  RELEASE_OWNER,
]
CONFIGURATION_RUNNERS = {
  **{
    f"auth/tests/legacy/connection-string.json::test[{index}]": (
      "spec/support/auth_config_runner.lua"
    )
    for index in (*range(4, 12), 14, 15)
  },
  "uri-options/tests/auth-options.json::test[1]": "spec/support/config_runner.lua",
}
CONFIGURATION_CASES = frozenset(CONFIGURATION_RUNNERS)
PROSE_REQUIREMENTS = {
  "auth/auth.md::gssapi-concurrent-contexts": (
    "AUTH-040",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
  "auth/auth.md::gssapi-credential-normalization": (
    "AUTH-031", "spec/support/auth_config_runner.lua", "none"
  ),
  "auth/auth.md::gssapi-default-credential-standalone": (
    "AUTH-035",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
  "auth/auth.md::gssapi-default-runtime-provider": (
    "AUTH-034", "spec/unit/runtime_gssapi_spec.lua", "packaged-runtime"
  ),
  "auth/auth.md::gssapi-hostname-canonicalization": (
    "AUTH-032",
    "spec/unit/auth_gssapi_hostname_spec.lua",
    "deterministic-runtime",
  ),
  "auth/auth.md::gssapi-live-canonicalized-host": (
    "AUTH-037",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
  "auth/auth.md::gssapi-password-credential-standalone": (
    "AUTH-036",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
  "auth/auth.md::gssapi-replica-set": (
    "AUTH-039",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
  "auth/auth.md::gssapi-sasl-conversation": (
    "AUTH-033", "spec/unit/auth_gssapi_spec.lua", "deterministic-runtime"
  ),
  "auth/auth.md::gssapi-service-host": (
    "AUTH-038",
    "spec/integration/auth_gssapi_live_spec.lua",
    "ubuntu-24.04-lua-5.4-gssapi-live",
  ),
}
PROVIDER_CLAIMS = [
  {
    "lua": "5.4",
    "operating_system": "Ubuntu 24.04",
    "provider": "packaged system GSSAPI adapter",
    "required_environment": "ubuntu-24.04-lua-5.4-gssapi-live",
  },
]
RATCHETS = {
  "classified": 21,
  "configuration_cases": 11,
  "passed": 21,
  "prose_requirements": 10,
  "supported": 21,
}


class ScopeError(ValueError):
  """Raised when the v0.10.2 GSSAPI boundary loses exact evidence."""


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


def _validate_track(activities: dict[str, dict[str, str]]) -> None:
  actual = [
    activity_id
    for activity_id, activity in activities.items()
    if activity["track"] == TRACK
  ]
  if actual != TRACK_ORDER:
    raise ScopeError("v0.10.2 GSSAPI track inventory changed")


def _validate_owner(
  identity: str,
  owner: str,
  activities: dict[str, dict[str, str]],
) -> None:
  if owner not in TARGET_OWNERS or owner not in activities:
    raise ScopeError(f"v0.10.2 evidence has an unaccounted owner: {identity}")

  activity = activities[owner]
  if activity["track"] != TRACK:
    raise ScopeError(f"v0.10.2 owner is outside the declared track: {identity}")

  allowed = {"in_progress", "completed"} if owner == CLOSURE_OWNER else {"completed"}
  if activity["status"] not in allowed:
    raise ScopeError(f"v0.10.2 evidence owner is incomplete: {identity}: {owner}")


def _validate_passing(
  identity: str,
  evidence: dict[str, Any],
  activities: dict[str, dict[str, str]],
) -> None:
  _validate_owner(identity, evidence.get("activity"), activities)

  if evidence.get("status") != "passed":
    raise ScopeError(f"v0.10.2 GSSAPI evidence remains deferred: {identity}")
  if not evidence.get("last_execution"):
    raise ScopeError(f"v0.10.2 GSSAPI evidence has no execution command: {identity}")

  runner = evidence.get("runner")
  if not isinstance(runner, str) or runner.startswith(("none:", "pending:")):
    raise ScopeError(f"v0.10.2 GSSAPI evidence has no exact runner: {identity}")
  if not (ROOT / runner).is_file():
    raise ScopeError(f"v0.10.2 GSSAPI runner does not exist: {identity}")


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
        f"v0.10.2 GSSAPI {name} ratchet regressed "
        f"from {minimum} to {current[name]}"
      )


def classify(
  cases: dict[str, dict[str, Any]],
  requirements: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  _validate_track(activities)
  configuration = {
    identity: cases[identity]
    for identity in CONFIGURATION_CASES
    if identity in cases
  }
  prose = {
    identity: requirement
    for identity, requirement in requirements.items()
    if identity.startswith("auth/auth.md::gssapi-")
  }

  if set(configuration) != CONFIGURATION_CASES:
    missing = sorted(CONFIGURATION_CASES - set(configuration))
    raise ScopeError(f"v0.10.2 GSSAPI configuration cases are missing: {missing}")
  if set(prose) != set(PROSE_REQUIREMENTS):
    missing = sorted(set(PROSE_REQUIREMENTS) - set(prose))
    stale = sorted(set(prose) - set(PROSE_REQUIREMENTS))
    raise ScopeError(
      f"v0.10.2 GSSAPI prose requirements differ: "
      f"missing={missing}, stale={stale}"
    )

  statuses: Counter[str] = Counter()
  suites: dict[str, Counter[str]] = {}

  for identity, case in sorted(configuration.items()):
    _validate_passing(identity, case, activities)
    if (
      case.get("activity") != "AUTH-031"
      or case.get("runner") != CONFIGURATION_RUNNERS[identity]
      or case.get("required_environment") != "none"
    ):
      raise ScopeError(f"v0.10.2 GSSAPI configuration evidence is stale: {identity}")
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
      raise ScopeError(f"v0.10.2 GSSAPI prose evidence is stale: {identity}")
    statuses["passed"] += 1
    suites.setdefault(requirement["suite"], Counter())["passed"] += 1

  for identity, evidence in {**cases, **requirements}.items():
    if (
      evidence.get("activity") in TARGET_OWNERS
      and evidence.get("status") == "deferred_unsupported"
    ):
      raise ScopeError(
        f"v0.10.2 GSSAPI activity still owns deferred evidence: {identity}"
      )

  report = {
    "configuration_cases": dict(sorted(configuration.items())),
    "evidence": {
      "configuration_cases": len(configuration),
      "prose_requirements": len(prose),
    },
    "prose_requirements": dict(sorted(prose.items())),
    "provider_claims": PROVIDER_CLAIMS,
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
    "type": "v0.10.2-gssapi-scope",
  }
  validate_scope_ratchets(report)
  return report


def generate() -> dict[str, Any]:
  return classify(load_cases(), load_requirements(), load_activities())


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"v0.10.2 GSSAPI scope: {exc}")
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("v0.10.2 GSSAPI scope report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  print(
    f"v0.10.2 GSSAPI scope: {report['summary']['passed']} passing "
    "requirements, 0 planned"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
