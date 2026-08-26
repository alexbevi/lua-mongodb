#!/usr/bin/env python3
"""Validate and report production-core v1 conformance ownership."""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
OUTPUT = ROOT / "spec" / "release" / "scope.json"
AMBIGUOUS_OWNERS = {"REL-001", "REL-009"}
RELEASE_FIXTURE_OWNERS = {
  "REL-002", "REL-003", "REL-004", "REL-005", "REL-006", "REL-010", "REL-011",
  "REL-012", "REL-013", "REL-014", "REL-015", "REL-016", "REL-017",
  "REL-018", "REL-019", "REL-020", "REL-021", "REL-022", "REL-023",
  "REL-024", "REL-025", "REL-026", "REL-027", "REL-028",
  "REL-029", "REL-030", "REL-031", "REL-034", "REL-035", "REL-036",
  "REL-037", "REL-038", "REL-039", "REL-040", "REL-041",
}
ADDITIONAL_REASONS = {
  **{
    f"LB-{index:03d}": "load-balanced deployment behavior is outside production-core v1"
    for index in range(1, 22)
  },
  "ADV-001": "change streams are outside production-core v1",
  "ADV-002": "GridFS is outside production-core v1",
  "ADV-003": "SRV and TXT discovery are outside production-core v1",
  "ADV-004": "wire compression is outside production-core v1",
  "ADV-005": "sharded deployment behavior is outside production-core v1",
  "ADV-006": "load-balanced deployment behavior is outside production-core v1",
  "ADV-007": "client bulk write is outside production-core v1",
  "CSOT-001": "deprecated index maxTimeMS handling is outside production-core v1",
  "GFS-001": "empty GridFS uploads are outside production-core v1",
  "GFS-002": "chunked GridFS uploads are outside production-core v1",
  "GFS-003": "GridFS upload aborts are outside production-core v1",
  "GFS-004": "GridFS readable-stream uploads are outside production-core v1",
  "GFS-005": "GridFS download streams are outside production-core v1",
  "GFS-006": "GridFS download copying is outside production-core v1",
  "GFS-007": "GridFS revision downloads are outside production-core v1",
  "GFS-008": "GridFS named download copying is outside production-core v1",
  "GFS-009": "GridFS file deletion is outside production-core v1",
  "GFS-010": "GridFS revision deletion is outside production-core v1",
  "GFS-011": "GridFS file discovery is outside production-core v1",
  "GFS-012": "GridFS file renaming is outside production-core v1",
  "GFS-013": "GridFS revision renaming is outside production-core v1",
  "GFS-014": "GridFS bucket drops are outside production-core v1",
  "CBW-001": "client bulk update models are outside production-core v1",
  "CBW-002": "client bulk delete models are outside production-core v1",
  "CBW-003": "client bulk verbose results are outside production-core v1",
  "CBW-004": "client bulk command options are outside production-core v1",
  "CBW-005": "client bulk raw data is outside production-core v1",
  "CBW-006": "individual client bulk write errors are outside production-core v1",
  "CBW-007": "client bulk count batching is outside production-core v1",
  "CBW-017": "client bulk message-size batching is outside production-core v1",
  "CBW-018": "client bulk batch outcome merging is outside production-core v1",
  "CBW-008": "unacknowledged client bulk writes are outside production-core v1",
  "CBW-009": "client bulk sessions are outside production-core v1",
  "CBW-010": "client bulk transactions are outside production-core v1",
  "CBW-011": "retryable client bulk writes are outside production-core v1",
  "CBW-012": "client bulk timeout behavior is outside production-core v1",
  "CBW-013": "client bulk partial results are outside production-core v1",
  "CBW-014": "client bulk write concern errors are outside production-core v1",
  "CBW-015": "client bulk command failures are outside production-core v1",
  "CBW-016": "client bulk cursor cleanup is outside production-core v1",
  "AUTH-002": "authentication credential normalization beyond SCRAM is outside production-core v1",
  "AUTH-003": "PLAIN authentication is outside production-core v1",
  "AUTH-004": "X.509 authentication is outside production-core v1",
  "AUTH-005": "MONGODB-AWS authentication is outside production-core v1",
  "AUTH-010": "MONGODB-OIDC credential configuration is outside production-core v1",
  "AUTH-024": "MONGODB-OIDC callback configuration is outside production-core v1",
  "AUTH-011": "MONGODB-OIDC machine authentication is outside production-core v1",
  "AUTH-025": "MONGODB-OIDC machine token caching is outside production-core v1",
  "AUTH-026": "MONGODB-OIDC callback coordination is outside production-core v1",
  "AUTH-027": "MONGODB-OIDC human allowed-host enforcement is outside production-core v1",
  "AUTH-028": "MONGODB-OIDC human authentication is outside production-core v1",
  "AUTH-029": "MONGODB-OIDC human access-token caching is outside production-core v1",
  "AUTH-030": "MONGODB-OIDC human refresh credential reuse is outside production-core v1",
  "AUTH-012": "MONGODB-OIDC human authentication recovery is outside production-core v1",
  "AUTH-017": "MONGODB-OIDC speculative authentication is outside production-core v1",
  "AUTH-018": "MONGODB-OIDC reauthentication is outside production-core v1",
  "AUTH-031": "GSSAPI credential normalization is additional authentication work",
  "AUTH-020": "MONGODB-AWS credential-source rules are outside production-core v1",
  "ADV-009": "logging, telemetry, and backpressure are outside production-core v1",
  "ADV-010": "client-side encryption requires a separate additional design",
  "ADV-011": "expanded command, cursor, and session APIs are outside production-core v1",
  "LEG-001": "deprecated count retry behavior is outside production-core v1",
  "LEG-002": "deprecated count timeout behavior is outside production-core v1",
  "LEG-003": "legacy mapReduce is outside production-core v1",
  "LEG-004": "legacy mapReduce retries are outside production-core v1",
  "LEG-005": "database aggregation is outside production-core v1",
  "LEG-006": "database aggregate retries are outside production-core v1",
  "LEG-007": "database aggregate timeout behavior is outside production-core v1",
  "LEG-008": "empty-batch command cursor behavior is outside production-core v1",
  "LEG-009": "tailable cursors are outside production-core v1",
  "LEG-010": "awaitData cursors are outside production-core v1",
  "LEG-011": "awaitData timeout validation is outside production-core v1",
  "LEG-012": "awaitData wait budgets are outside production-core v1",
  "LEG-013": "awaitData cancellation is outside production-core v1",
  "REL-053": "legacy API target-version exclusions are outside production-core v1",
  "REL-055": "v0.7 client bulk conformance closure is outside production-core v1",
  "ADV-012": "proxy transports are outside production-core v1",
  "ADV-013": "runtime DNS resolution is outside production-core v1",
  "ADV-014": "initial DNS seedlist discovery is outside production-core v1",
  "ADV-015": "SRV polling is outside production-core v1",
  "CFG-004": "unbounded connection establishment is outside production-core v1",
  "CMAP-002": "authentication failure pool clearing is outside production-core v1",
  "CMAP-003": "application error pool-clear ordering is outside production-core v1",
  "CMAP-004": "interrupting in-use connections is outside production-core v1",
  "CON-010": "complete load-balanced unified execution is outside production-core v1",
  "CS-001": "change stream option forwarding is outside production-core v1",
  "CS-002": "cooperative change stream iteration is outside production-core v1",
  "CS-003": "change stream resume-token tracking is outside production-core v1",
  "CS-004": "automatic change stream resume is outside production-core v1",
  "CS-005": "change stream resume positioning is outside production-core v1",
  "CS-006": "database change streams are outside production-core v1",
  "CS-007": "cluster change streams are outside production-core v1",
  "CS-008": "change stream timeout behavior is outside production-core v1",
  "CS-009": "change stream images on collection creation are outside production-core v1",
  "CS-010": "change stream images on collection modification are outside production-core v1",
  "CS-011": "change stream pre/post image events are outside production-core v1",
  "DNS-001": "sharded SRV host limiting is outside production-core v1",
  "IDX-001": "single Search index creation is outside production-core v1",
  "IDX-002": "multiple Search index creation is outside production-core v1",
  "IDX-003": "Search index listing is outside production-core v1",
  "IDX-004": "Search index updates are outside production-core v1",
  "IDX-005": "Search index deletion is outside production-core v1",
  "IDX-006": "Search index concern omission is outside production-core v1",
  "REL-051": "complete v0.5 change stream conformance is outside production-core v1",
  "SDAM-004": "sharded topology shutdown is outside production-core v1",
  "SDAM-005": "server monitoring modes are outside production-core v1",
  "SDAM-006": "monitor error and timeout handling is outside production-core v1",
  "SDAM-007": "server-check cancellation is outside production-core v1",
  "SDAM-008": "streaming monitor deadline extension is outside production-core v1",
  "SES-004": "snapshot transaction rejection is outside production-core v1",
  "SES-005": "snapshot server-version enforcement is outside production-core v1",
  "SES-006": "snapshot timestamp capture is outside production-core v1",
  "SES-007": "snapshot-time access is outside production-core v1",
  "SES-008": "snapshot command concerns are outside production-core v1",
  "TXN-003": "mongos transaction pinning is outside production-core v1",
  "TXN-004": "mongos transaction unpinning is outside production-core v1",
  "TXN-005": "sharded transaction recovery tokens are outside production-core v1",
  "TXN-006": "non-transient mongos pin retention is outside production-core v1",
  "TXN-007": "transient mongos unpinning is outside production-core v1",
}


class ScopeError(ValueError):
  """Raised when release conformance lacks an accountable owner."""


def load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  plan = json.loads(plan_path.read_text(encoding="utf-8"))
  progress = json.loads(progress_path.read_text(encoding="utf-8"))
  states = progress.get("activities", {})
  return {
    activity["id"]: {
      "milestone": activity["milestone"],
      "status": states.get(activity["id"], {}).get("status", "pending"),
    }
    for activity in plan["activities"]
  }


def classify(
  cases: dict[str, dict[str, Any]],
  activities: dict[str, dict[str, str]],
) -> dict[str, Any]:
  statuses = Counter()
  deferred_by_activity = Counter()
  deferred_by_scope = Counter()

  for identity, case in cases.items():
    status = case.get("status")
    owner = case.get("activity")

    if status not in {
      "deferred_unsupported",
      "excluded_scope",
      "passed",
      "unsupported",
    }:
      raise ScopeError(f"unknown conformance status for {identity}: {status}")

    if owner not in activities:
      raise ScopeError(f"unknown conformance owner for {identity}: {owner}")

    statuses[status] += 1

    if status in {"excluded_scope", "unsupported"}:
      reason = case.get("reason")

      if not isinstance(reason, str) or not reason.strip():
        raise ScopeError(f"terminal conformance case has no reason: {identity}")

      continue

    if status == "passed":
      continue

    if owner in AMBIGUOUS_OWNERS:
      raise ScopeError(f"ambiguous release owner {owner}: {identity}")

    reason = case.get("reason")

    if not isinstance(reason, str) or not reason.strip():
      raise ScopeError(f"deferred conformance case has no reason: {identity}")

    activity = activities[owner]

    if activity["status"] == "completed":
      raise ScopeError(f"deferred case is owned by completed activity {owner}: {identity}")

    if activity["milestone"] == "production-core-v1":
      if owner not in RELEASE_FIXTURE_OWNERS:
        raise ScopeError(f"invalid production-core release owner {owner}: {identity}")

      scope = "applicable-release-gap"
    elif activity["milestone"] == "additional":
      if owner not in ADDITIONAL_REASONS:
        raise ScopeError(f"additional owner has no scope reason {owner}: {identity}")

      scope = "additional-exclusion"
    else:
      raise ScopeError(f"unknown release milestone for {identity}: {activity['milestone']}")

    deferred_by_activity[owner] += 1
    deferred_by_scope[scope] += 1

  return {
    "deferred_by_activity": dict(sorted(deferred_by_activity.items())),
    "deferred_by_scope": dict(sorted(deferred_by_scope.items())),
    "additional_reasons": ADDITIONAL_REASONS,
    "schema_version": 1,
    "statuses": dict(sorted(statuses.items())),
    "total_cases": len(cases),
    "type": "production-core-release-scope",
  }


def release_cases(
  capabilities_path: Path = CAPABILITIES,
  ledger_path: Path = LEDGER,
) -> dict[str, dict[str, Any]]:
  capabilities = json.loads(capabilities_path.read_text(encoding="utf-8"))["tests"]
  ledger = json.loads(ledger_path.read_text(encoding="utf-8"))["cases"]
  result = {}

  for identity, record in ledger.items():
    value = {
      "activity": record["activity"],
      "status": record["status"],
    }

    if record["status"] != "passed":
      capability = capabilities.get(identity)
      reason = record.get("reason")

      if reason is None and capability is not None:
        reason = capability.get("reason")

      value["reason"] = (
        reason
        or ADDITIONAL_REASONS.get(record["activity"])
        or f"awaits {record['activity']} conformance"
      )

    result[identity] = value

  return result


def generate() -> dict[str, Any]:
  return classify(release_cases(), load_activities())


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  args = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, ScopeError) as exc:
    print(f"release scope: {exc}")
    return 2

  if args.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("release scope report is stale")
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  report = json.loads(encoded)
  scopes = report["deferred_by_scope"]
  print(
    f"release scope: {report['total_cases']} cases; "
    f"{scopes.get('applicable-release-gap', 0)} applicable gaps, "
    f"{scopes.get('additional-exclusion', 0)} additional exclusions"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
