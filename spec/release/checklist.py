#!/usr/bin/env python3
"""Validate and report standardized-logging v0.10.6 release readiness."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.compatibility import matrix  # noqa: E402
from spec.release import scope  # noqa: E402
from spec.v04 import scope as v04_scope  # noqa: E402
from spec.v05 import scope as v05_scope  # noqa: E402
from spec.v06 import scope as v06_scope  # noqa: E402
from spec.v07 import scope as v07_scope  # noqa: E402
from spec.v08 import scope as v08_scope  # noqa: E402
from spec.v09 import scope as v09_scope  # noqa: E402
from spec.v10 import scope as v10_scope  # noqa: E402
from spec.v102 import scope as v102_scope  # noqa: E402
from spec.v103 import scope as v103_scope  # noqa: E402


PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
OUTPUT = ROOT / "spec" / "release" / "checklist.json"
ROCKSPEC = ROOT / "mongodb-0.10.6-1.rockspec"
RELEASE_VERSION = "0.10.6"
ROCKSPEC_VERSION = f"{RELEASE_VERSION}-1"
CLASSIFIED_CASES = 5524
MINIMUM_PASSED_CASES = 4484
MAXIMUM_ADDITIONAL_EXCLUSIONS = 1023
AUDITS = {
  "cleanup": ["REL-042", "REL-043"],
  "packaging": ["REL-007"],
  "security": ["REL-008"],
}
RELEASE_ADDITIONS = ["ADV-003", "ADV-013", "ADV-014", "ADV-015"]
AUTHENTICATION_GATES = [
  f"AUTH-{index:03d}"
  for index in range(1, 31)
  if index != 19
]
V04_GATES = [
  "ADV-005",
  "CON-002",
  "SES-003",
  "SES-004",
  "SES-005",
  "SES-008",
  "SES-006",
  "SES-007",
  "IDX-001",
  "IDX-002",
  "IDX-003",
  "IDX-004",
  "IDX-005",
  "IDX-006",
  "CI-005",
  "SDAM-004",
  "SDAM-005",
  "SDAM-006",
  "SDAM-008",
  "SDAM-007",
  "CFG-004",
  "CMAP-002",
  "CMAP-003",
  "CMAP-004",
  "DNS-001",
  "TXN-003",
  "TXN-004",
  "TXN-005",
  "TXN-006",
  "TXN-007",
  "CMP-002",
  "REL-049",
]
V04_RELEASE_ACTIVITY = "REL-050"
V05_GATES = [
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
]
V05_RELEASE_ACTIVITY = "REL-052"
V06_GATES = [
  "ADV-011",
  *(f"LEG-{index:03d}" for index in range(1, 14)),
  "REL-053",
]
V06_RELEASE_ACTIVITY = "REL-054"
V07_GATES = [
  "ADV-007",
  "CBW-001",
  "CBW-002",
  "CBW-003",
  "CBW-004",
  "CBW-005",
  "CBW-006",
  "CBW-013",
  "CBW-014",
  "CBW-015",
  "CBW-016",
  "CBW-007",
  "CBW-017",
  "CBW-018",
  "CBW-008",
  "CBW-009",
  "CBW-010",
  "CBW-011",
  "CBW-012",
  "REL-055",
]
V07_RELEASE_ACTIVITY = "REL-056"
V08_GATES = [
  "ADV-004",
  *(f"WIRE-{index:03d}" for index in range(2, 10)),
  "CON-008",
]
V08_RELEASE_ACTIVITY = "REL-057"
V09_GATES = [
  "ADV-002",
  *(f"GFS-{index:03d}" for index in range(1, 15)),
  "CON-009",
]
V09_RELEASE_ACTIVITY = "REL-058"
V10_CORE_GATES = [
  "ADV-006",
  "LB-001",
  "LB-002",
  "LB-003",
  "LB-004",
  "LB-005",
  "LB-006",
  "LB-007",
  "LB-008",
  "LB-019",
  "LB-020",
  "LB-009",
  "LB-010",
  "LB-011",
  "LB-012",
  "LB-013",
  "LB-014",
  "LB-015",
  "LB-016",
  "LB-021",
  "LB-017",
  "LB-018",
]
V10_TERMINAL_GATES = ["TLS-002", "ADV-012"]
V10_CONFORMANCE_ACTIVITY = "CON-010"
V10_GATES = [
  *V10_CORE_GATES,
  *V10_TERMINAL_GATES,
  V10_CONFORMANCE_ACTIVITY,
]
V10_RELEASE_ACTIVITY = "REL-059"
MAINTENANCE_GATES = ["CSOT-001", "BSON-010"]
MAINTENANCE_RELEASE_ACTIVITY = "REL-060"
V102_GATES = [
  "AUTH-019",
  *(f"AUTH-{index:03d}" for index in range(31, 41)),
]
V102_CONFORMANCE_ACTIVITY = "CON-013"
V102_RELEASE_ACTIVITY = "REL-061"
V103_GATES = ["ADV-009", "LOG-008", "LOG-009", "LOG-001"]
V103_CONFORMANCE_ACTIVITY = "CON-014"
V103_RELEASE_ACTIVITY = "REL-062"
V104_GATES = [
  "LOG-002",
  "LOG-003",
  "LOG-010",
  "LOG-011",
  "LOG-004",
  "LOG-012",
  "LOG-013",
  "LOG-014",
  "LOG-005",
  "LOG-015",
  "LOG-016",
  "LOG-017",
  "LOG-018",
  "LOG-006",
  "LOG-019",
  "LOG-020",
  "LOG-021",
  "LOG-022",
  "LOG-023",
  "LOG-007",
  "LOG-024",
  "LOG-025",
  "LOG-026",
]
V104_CONFORMANCE_ACTIVITY = "CON-015"
V104_RELEASE_ACTIVITY = "REL-063"
V105_GATES = ["SEL-002", "SEL-003"]
V105_CONFORMANCE_ACTIVITY = "CON-016"
V105_RELEASE_ACTIVITY = "REL-064"
V106_GATES = ["SDAM-009", "SDAM-010", "CMAP-005", "CMAP-006"]
V106_CONFORMANCE_ACTIVITY = "CON-017"
V106_RELEASE_ACTIVITY = "REL-065"
V106_STABILIZATION_ACTIVITIES = ["CI-012", "CI-013"]
CSOT_IDENTITIES = {
  f"client-side-operations-timeout/tests/deprecated-options.json::test[{index}]"
  for index in (79, 82, 85)
}
OBJECTID_IDENTITIES = {"bson-objectid/objectid.md::post-fork-random"}


class ChecklistError(ValueError):
  """Raised when the standardized-logging release is not ready."""


def load_json(path: Path) -> dict[str, Any]:
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ChecklistError(f"cannot read release input {path}: {exc}") from exc


def require_text(path: Path, expected: str) -> None:
  try:
    contents = path.read_text(encoding="utf-8")
  except OSError as exc:
    raise ChecklistError(f"cannot read release document {path}: {exc}") from exc

  if expected not in contents:
    raise ChecklistError(f"{path.relative_to(ROOT)} is missing {expected!r}")


def completed_activity(progress: dict[str, Any], activity_id: str) -> None:
  activity = progress.get("activities", {}).get(activity_id, {})

  if activity.get("status") != "completed":
    raise ChecklistError(f"release activity is not completed: {activity_id}")

  green = [
    item
    for item in activity.get("evidence", [])
    if item.get("phase") == "green" and item.get("exit_code") == 0
  ]

  if not green:
    raise ChecklistError(f"release activity has no green evidence: {activity_id}")


def v106_track_activity_ids(plan: dict[str, Any]) -> list[str]:
  return [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-6-topology-pool-logging"
  ]


def passed_owner_evidence(
  entries: dict[str, dict[str, Any]],
  activity_id: str,
  expected_identities: set[str],
) -> dict[str, dict[str, Any]]:
  owned = {
    identity: entry
    for identity, entry in entries.items()
    if entry.get("activity") == activity_id
  }

  if set(owned) != expected_identities:
    raise ChecklistError(
      f"{activity_id} release identities do not match the maintenance scope"
    )

  for entry in owned.values():
    if entry.get("status") != "passed":
      raise ChecklistError(f"{activity_id} release requirement is not passed")

    for field in ("runner", "last_execution"):
      value = entry.get(field)

      if not isinstance(value, str) or not value.strip():
        raise ChecklistError(
          f"{activity_id} release requirement has no {field} evidence"
        )

  return owned


def release_metadata() -> dict[str, str]:
  if not ROCKSPEC.exists():
    raise ChecklistError(f"release rockspec is missing: {ROCKSPEC.name}")

  rockspec = ROCKSPEC.read_text(encoding="utf-8")
  package = re.search(r'^package = "([^"]+)"$', rockspec, re.MULTILINE)
  version = re.search(r'^version = "([^"]+)"$', rockspec, re.MULTILINE)

  if package is None or package.group(1) != "mongodb":
    raise ChecklistError("release rockspec package must be mongodb")

  if version is None or version.group(1) != ROCKSPEC_VERSION:
    raise ChecklistError(
      f"release rockspec version must be {ROCKSPEC_VERSION}"
    )

  require_text(
    ROOT / "src" / "mongodb" / "handshake" / "metadata.lua",
    f'local DRIVER_VERSION = "{RELEASE_VERSION}"',
  )
  require_text(
    ROOT / "CHANGELOG.md",
    f"## [{RELEASE_VERSION}] - 2026-08-28",
  )
  return {
    "package": package.group(1),
    "rockspec": ROCKSPEC.name,
    "rockspec_version": version.group(1),
    "version": RELEASE_VERSION,
  }


def generate() -> dict[str, Any]:
  plan = load_json(PLAN)
  progress = load_json(PROGRESS)
  ledger = load_json(LEDGER)
  catalog = load_json(CATALOG)
  activities = {
    activity["id"]: activity
    for activity in plan.get("activities", [])
  }
  v04_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-4-sharded-parity"
  ]

  if v04_track != [*V04_GATES, V04_RELEASE_ACTIVITY]:
    raise ChecklistError("v0.4 release gate inventory does not match the track")

  api_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-5-v0-7-api"
  ]
  v05_prefix = [*V05_GATES, V05_RELEASE_ACTIVITY]

  if api_track[:len(v05_prefix)] != v05_prefix:
    raise ChecklistError("v0.5 release gate inventory does not match the track")

  v06_segment = [
    "ADV-007",
    *V06_GATES,
    V06_RELEASE_ACTIVITY,
  ]
  if api_track[len(v05_prefix):len(v05_prefix) + len(v06_segment)] != v06_segment:
    raise ChecklistError("v0.6 release gate inventory does not match the track")

  v07_offset = len(v05_prefix) + len(v06_segment)
  v07_segment = [
    *V07_GATES[1:],
    V07_RELEASE_ACTIVITY,
  ]
  if api_track[v07_offset:] != v07_segment:
    raise ChecklistError("v0.7 release gate inventory does not match the track")

  compression_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-8-wire-compression"
  ]
  if compression_track != [
    *V08_GATES,
    V08_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError("v0.8 release gate inventory does not match the track")

  gridfs_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-9-gridfs"
  ]
  if gridfs_track != [
    *V09_GATES,
    V09_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError("v0.9 release gate inventory does not match the track")

  load_balancing_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-load-balancing"
  ]
  if load_balancing_track != [
    *V10_CORE_GATES,
    V10_CONFORMANCE_ACTIVITY,
    V10_RELEASE_ACTIVITY,
    *V10_TERMINAL_GATES,
  ]:
    raise ChecklistError("v0.10 release gate inventory does not match the track")

  maintenance_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-1-maintenance"
  ]
  if maintenance_track != [
    *MAINTENANCE_GATES,
    MAINTENANCE_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError(
      "v0.10.1 release gate inventory does not match the track"
    )

  gssapi_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-2-gssapi"
  ]
  if gssapi_track != [
    *V102_GATES,
    V102_CONFORMANCE_ACTIVITY,
    V102_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError(
      "v0.10.2 release gate inventory does not match the track"
    )

  logging_foundation_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-3-logging-foundation"
  ]
  if logging_foundation_track != [
    *V103_GATES,
    V103_CONFORMANCE_ACTIVITY,
    V103_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError(
      "v0.10.3 release gate inventory does not match the track"
    )

  command_logging_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-4-command-logging"
  ]
  if command_logging_track != [
    *V104_GATES,
    V104_CONFORMANCE_ACTIVITY,
    V104_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError(
      "v0.10.4 release gate inventory does not match the track"
    )

  server_selection_logging_track = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("track") == "v0-10-5-server-selection-logging"
  ]
  if server_selection_logging_track != [
    *V105_GATES,
    V105_CONFORMANCE_ACTIVITY,
    V105_RELEASE_ACTIVITY,
  ]:
    raise ChecklistError(
      "v0.10.5 release gate inventory does not match the track"
    )

  topology_pool_logging_track = v106_track_activity_ids(plan)
  if topology_pool_logging_track != [
    *V106_GATES,
    V106_CONFORMANCE_ACTIVITY,
    V106_RELEASE_ACTIVITY,
    *V106_STABILIZATION_ACTIVITIES,
  ]:
    raise ChecklistError(
      "v0.10.6 release gate inventory does not match the track"
    )

  production_core = [
    activity["id"]
    for activity in plan.get("activities", [])
    if activity.get("milestone") == "production-core-v1"
      and activity.get("id") != "REL-009"
  ]

  for activity_id in production_core:
    completed_activity(progress, activity_id)

  for activity_id in RELEASE_ADDITIONS:
    if activity_id not in activities:
      raise ChecklistError(f"unknown release addition activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in AUTHENTICATION_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown authentication gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V04_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.4 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V05_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.5 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V06_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.6 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V07_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.7 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V08_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.8 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V09_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.9 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in V10_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in MAINTENANCE_GATES:
    if activity_id not in activities:
      raise ChecklistError(f"unknown maintenance gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in [*V102_GATES, V102_CONFORMANCE_ACTIVITY]:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10.2 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in [*V103_GATES, V103_CONFORMANCE_ACTIVITY]:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10.3 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in [*V104_GATES, V104_CONFORMANCE_ACTIVITY]:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10.4 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in [*V105_GATES, V105_CONFORMANCE_ACTIVITY]:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10.5 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  for activity_id in [
    *V106_GATES,
    V106_CONFORMANCE_ACTIVITY,
    *V106_STABILIZATION_ACTIVITIES,
  ]:
    if activity_id not in activities:
      raise ChecklistError(f"unknown v0.10.6 gate activity: {activity_id}")

    completed_activity(progress, activity_id)

  csot_evidence = passed_owner_evidence(
    ledger.get("cases", {}),
    "CSOT-001",
    CSOT_IDENTITIES,
  )
  objectid_evidence = passed_owner_evidence(
    catalog.get("requirements", {}),
    "BSON-010",
    OBJECTID_IDENTITIES,
  )

  for activity_ids in AUDITS.values():
    for activity_id in activity_ids:
      if activity_id not in activities:
        raise ChecklistError(f"unknown release audit activity: {activity_id}")

      completed_activity(progress, activity_id)

  scope_report = scope.generate()
  v04_report = v04_scope.generate()
  v05_report = v05_scope.generate()
  v06_report = v06_scope.generate()
  v07_report = v07_scope.generate()
  v08_report = v08_scope.generate()
  v09_report = v09_scope.generate()
  v10_report = v10_scope.generate()
  v102_report = v102_scope.generate()
  v103_report = v103_scope.generate()
  statuses = scope_report.get("statuses", {})
  classified = sum(statuses.values())
  applicable_gaps = scope_report.get("deferred_by_scope", {}).get(
    "applicable-release-gap",
    0,
  )
  additional_exclusions = scope_report.get("deferred_by_scope", {}).get(
    "additional-exclusion",
    0,
  ) + statuses.get("excluded_scope", 0)
  unsupported_cases = statuses.get("unsupported", 0)
  ledger_summary = ledger.get("summary", {})

  if applicable_gaps != 0:
    raise ChecklistError(
      f"production-core release has {applicable_gaps} applicable gaps"
    )

  if classified != scope_report.get("total_cases"):
    raise ChecklistError("release scope contains unclassified cases")

  if classified != CLASSIFIED_CASES:
    raise ChecklistError(
      f"release scope must classify {CLASSIFIED_CASES} pinned cases"
    )

  if statuses.get("passed", 0) < MINIMUM_PASSED_CASES:
    raise ChecklistError("production-core passing-case ratchet regressed")

  if additional_exclusions > MAXIMUM_ADDITIONAL_EXCLUSIONS:
    raise ChecklistError("production-core additional exclusions increased")

  if ledger_summary.get("cases") != classified:
    raise ChecklistError("conformance ledger and release scope totals differ")

  if ledger_summary.get("statuses") != statuses:
    raise ChecklistError("conformance ledger and release scope statuses differ")

  v04_summary = v04_report["summary"]
  if v04_summary["planned"] != 0:
    raise ChecklistError("v0.4 conformance still has planned cases")

  v05_summary = v05_report["summary"]
  if v05_summary["planned"] != 0:
    raise ChecklistError("v0.5 conformance still has planned cases")

  v06_summary = v06_report["summary"]
  if v06_summary["planned"] != 0:
    raise ChecklistError("v0.6 conformance still has planned cases")

  v07_summary = v07_report["summary"]
  if v07_summary["planned"] != 0:
    raise ChecklistError("v0.7 conformance still has planned cases")

  v08_summary = v08_report["summary"]
  if v08_summary["planned"] != 0:
    raise ChecklistError("v0.8 conformance still has planned requirements")

  v09_summary = v09_report["summary"]
  if v09_summary["planned"] != 0:
    raise ChecklistError("v0.9 conformance still has planned requirements")

  v10_summary = v10_report["summary"]
  if v10_summary["planned"] != 244:
    raise ChecklistError("v0.10 optional-suite inventory changed")

  v102_summary = v102_report["summary"]
  if v102_summary["planned"] != 0:
    raise ChecklistError("v0.10.2 GSSAPI conformance still has planned requirements")

  v103_summary = v103_report["summary"]
  server_selection_conformance = v103_report["server_selection_conformance"]
  standardized_logging_conformance = v103_report[
    "standardized_logging_conformance"
  ]

  if server_selection_conformance != {
    "cases": 11,
    "statuses": {"passed": 11},
  }:
    raise ChecklistError(
      "v0.10.5 server selection logging conformance is incomplete"
    )

  if standardized_logging_conformance != {
    "cases": 93,
    "requirements": 5,
    "requirement_statuses": {"passed": 5},
    "statuses": {
      "excluded_scope": 2,
      "passed": 89,
      "unsupported": 2,
    },
  }:
    raise ChecklistError(
      "v0.10.6 standardized logging conformance is incomplete"
    )

  compatibility = matrix.validate(matrix.load())
  profiles = sum(len(server["profiles"]) for server in compatibility["servers"])
  fast_workflow = ROOT / ".github" / "workflows" / "ci.yml"

  for expected in (
    "portable:",
    "compatibility-smoke:",
    "mongodb-8.0-sharded",
    "make check-fast",
    "planning/update_plan.py check --strict",
  ):
    require_text(fast_workflow, expected)

  full_workflow = ROOT / ".github" / "workflows" / "full-conformance.yml"

  for expected in (
    "copas-profile:",
    "linux-quality:",
    "linux-unified:",
    "linux-version-branches:",
    "linux-aggregate:",
    "macos-platform:",
    "macos-unified:",
    "macos-version-branches:",
    "macos-aggregate:",
    "compatibility:",
    "topology: [standalone, replicaset, sharded]",
    "make check-fast test-coverage",
    "spec/v04/scope.py",
    "spec/v05/scope.py",
    "spec/v06/scope.py",
    "spec/v07/scope.py",
    "spec/v08/scope.py",
    "spec/v09/scope.py",
    "spec/v10/scope.py",
    "spec/v102/scope.py",
    "spec/v103/scope.py",
    "--execution-report build/conformance/unified.json",
    "unified-linux-timing-sensitive-csot.json",
    "unified-pre-8.2.json",
  ):
    require_text(full_workflow, expected)

  return {
    "gates": {
      "ci": [
        "fast-compatibility-smoke",
        "fast-portable",
        "full-copas-profile",
        "full-compatibility",
        "full-linux-aggregate",
        "full-linux-quality",
        "full-linux-unified",
        "full-linux-version-branches",
        "full-macos-aggregate",
        "full-macos-platform",
        "full-macos-unified",
        "full-macos-version-branches",
      ],
      "compatibility": {
        "profiles": profiles,
        "rows": len(compatibility["servers"]),
      },
      "completed_audits": AUDITS,
      "completed_authentication_gates": AUTHENTICATION_GATES,
      "completed_release_additions": RELEASE_ADDITIONS,
      "completed_v0_4_gates": V04_GATES,
      "completed_v0_5_gates": V05_GATES,
      "completed_v0_6_gates": V06_GATES,
      "completed_v0_7_gates": V07_GATES,
      "completed_v0_8_gates": V08_GATES,
      "completed_v0_9_gates": V09_GATES,
      "completed_v0_10_gates": V10_GATES,
      "completed_v0_10_2_gates": [
        *V102_GATES,
        V102_CONFORMANCE_ACTIVITY,
      ],
      "completed_v0_10_3_gates": [
        *V103_GATES,
        V103_CONFORMANCE_ACTIVITY,
      ],
      "completed_v0_10_4_gates": [
        *V104_GATES,
        V104_CONFORMANCE_ACTIVITY,
      ],
      "completed_v0_10_5_gates": [
        *V105_GATES,
        V105_CONFORMANCE_ACTIVITY,
      ],
      "completed_v0_10_6_gates": [
        *V106_GATES,
        V106_CONFORMANCE_ACTIVITY,
        *V106_STABILIZATION_ACTIVITIES,
      ],
      "conformance": {
        "applicable_gaps": applicable_gaps,
        "classified_cases": classified,
        "passed_cases": statuses.get("passed", 0),
        "additional_exclusions": additional_exclusions,
        "unsupported_cases": unsupported_cases,
      },
      "production_core_prerequisites": len(production_core),
      "v0_4_conformance": {
        "classified_cases": v04_summary["classified"],
        "excluded_cases": v04_summary["excluded"],
        "exact_unified_cases": v04_report["evidence"][
          "exact_unified_cases"
        ],
        "passed_cases": v04_summary["passed"],
        "read_write_concern_passed": v04_report["suites"][
          "read-write-concern"
        ]["passed"],
        "target_version_exclusions": len(
          v04_report["target_version_exclusions"]
        ),
      },
      "v0_5_conformance": {
        "classified_cases": v05_summary["classified"],
        "excluded_cases": v05_summary["excluded"],
        "exact_unified_cases": v05_report["evidence"][
          "exact_unified_cases"
        ],
        "passed_cases": v05_summary["passed"],
        "target_version_exclusions": len(
          v05_report["target_version_exclusions"]
        ),
      },
      "v0_6_conformance": {
        "classified_cases": v06_summary["classified"],
        "excluded_cases": v06_summary["excluded"],
        "exact_unified_cases": v06_report["evidence"][
          "exact_unified_cases"
        ],
        "passed_cases": v06_summary["passed"],
        "reference_behavior_exclusions": len(
          v06_report["reference_behavior_exclusions"]
        ),
        "target_version_exclusions": len(
          v06_report["target_version_exclusions"]
        ),
      },
      "v0_7_conformance": {
        "classified_cases": v07_summary["classified"],
        "excluded_cases": v07_summary["excluded"],
        "exact_unified_cases": v07_report["evidence"][
          "exact_unified_cases"
        ],
        "passed_cases": v07_summary["passed"],
        "target_version_exclusions": len(
          v07_report["target_version_exclusions"]
        ),
      },
      "v0_8_conformance": {
        "classified_requirements": v08_summary["classified"],
        "configuration_cases": v08_report["evidence"][
          "configuration_cases"
        ],
        "passed_requirements": v08_summary["passed"],
        "prose_requirements": v08_report["evidence"][
          "prose_requirements"
        ],
      },
      "v0_9_conformance": {
        "classified_requirements": v09_summary["classified"],
        "csot_cases": v09_report["evidence"]["csot_cases"],
        "exact_unified_cases": (
          v09_report["evidence"]["gridfs_cases"]
          + v09_report["evidence"]["retryable_read_cases"]
          + v09_report["evidence"]["csot_cases"]
        ),
        "gridfs_cases": v09_report["evidence"]["gridfs_cases"],
        "passed_requirements": v09_summary["passed"],
        "prose_requirements": v09_report["evidence"]["prose_requirements"],
        "retryable_read_cases": v09_report["evidence"][
          "retryable_read_cases"
        ],
      },
      "v0_10_conformance": {
        "classified_requirements": v10_summary["classified"],
        "dedicated_cases": v10_report["evidence"]["dedicated_cases"],
        "exact_unified_cases": v10_report["evidence"]["exact_unified_cases"],
        "excluded_requirements": v10_summary["excluded"],
        "optional_requirements": v10_summary["planned"],
        "passed_requirements": v10_summary["passed"],
        "run_on_branches": v10_report["evidence"]["run_on_branches"],
        "unsupported_requirements": v10_summary["unsupported"],
      },
      "v0_10_2_conformance": {
        "classified_requirements": v102_summary["classified"],
        "configuration_cases": v102_report["evidence"][
          "configuration_cases"
        ],
        "passed_requirements": v102_summary["passed"],
        "prose_requirements": v102_report["evidence"][
          "prose_requirements"
        ],
        "provider_claims": v102_report["provider_claims"],
      },
      "v0_10_3_conformance": {
        "classified_requirements": v103_summary["classified"],
        "command_cases": v103_report["command_conformance"]["cases"],
        "command_statuses": v103_report["command_conformance"]["statuses"],
        "foundation_requirements": v103_report["evidence"][
          "foundation_requirements"
        ],
        "passed_requirements": v103_summary["passed"],
        "planned_requirements": v103_summary["planned"],
        "standardized_cases": v103_report["evidence"]["standardized_cases"],
        "unified_cases": v103_report["evidence"]["unified_cases"],
      },
      "v0_10_4_conformance": {
        "command_cases": v103_report["command_conformance"]["cases"],
        "command_statuses": v103_report["command_conformance"]["statuses"],
      },
      "v0_10_5_conformance": {
        "server_selection_cases": server_selection_conformance["cases"],
        "server_selection_statuses": server_selection_conformance["statuses"],
      },
      "v0_10_6_conformance": standardized_logging_conformance,
      "maintenance": {
        "activities": MAINTENANCE_GATES,
        "bson_objectid_requirements": len(objectid_evidence),
        "csot_cases": len(csot_evidence),
        "passed_requirements": len(csot_evidence) + len(objectid_evidence),
      },
    },
    "ready": True,
    "release": release_metadata(),
    "schema_version": 1,
    "type": "standardized-logging-release-checklist",
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  args = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (
    ChecklistError,
    matrix.MatrixError,
    scope.ScopeError,
    v04_scope.ScopeError,
    v05_scope.ScopeError,
    v06_scope.ScopeError,
    v07_scope.ScopeError,
    v08_scope.ScopeError,
    v09_scope.ScopeError,
    v10_scope.ScopeError,
    v102_scope.ScopeError,
    v103_scope.ScopeError,
  ) as exc:
    print(f"release checklist: {exc}")
    return 2

  if args.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("release checklist report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  conformance = report["gates"]["conformance"]
  compatibility = report["gates"]["compatibility"]
  print(
    f"release checklist: {report['release']['version']} ready; "
    f"{conformance['classified_cases']} classified cases, "
    f"{conformance['applicable_gaps']} applicable gaps, "
    f"{compatibility['rows']} compatibility rows"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
