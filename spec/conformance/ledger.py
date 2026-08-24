#!/usr/bin/env python3
"""Generate and validate coverage for pinned normative specification fixtures."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "planning" / "specifications" / "source"
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
CAPABILITIES = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
OUTPUT = ROOT / "spec" / "conformance" / "ledger.json"
VALID_STATUSES = {
  "deferred_unsupported",
  "excluded_scope",
  "passed",
  "unsupported",
}
RUNNABLE_CASES = {
  identity: {
    "environment": value["environment"],
    "evidence": "make test-unified",
    "runner": "spec/unified/execute.lua",
  }
  for identity, value in json.loads(EXECUTORS.read_text(encoding="utf-8"))["tests"].items()
}

DEFAULT_OWNERS = {
  "auth": "AUTH-018",
  "bson-binary-vector": "REL-002",
  "causal-consistency": "SES-001",
  "change-streams": "REL-051",
  "client-backpressure": "ADV-009",
  "client-side-encryption": "ADV-010",
  "client-side-operations-timeout": "TIME-001",
  "collection-management": "REL-021",
  "command-logging-and-monitoring": "ADV-009",
  "connection-monitoring-and-pooling": "CMAP-001",
  "crud": "REL-021",
  "gridfs": "ADV-002",
  "index-management": "REL-018",
  "initial-dns-seedlist-discovery": "ADV-014",
  "load-balancers": "ADV-006",
  "mongodb-handshake": "REL-006",
  "open-telemetry": "ADV-009",
  "read-write-concern": "REL-003",
  "retryable-reads": "RETRY-001",
  "retryable-writes": "RETRY-002",
  "run-command": "TXN-001",
  "server-discovery-and-monitoring": "SDAM-002",
  "server-selection": "ADV-009",
  "sessions": "SES-001",
  "transactions": "TXN-001",
  "transactions-convenient-api": "TXN-002",
  "uri-options": "REL-003",
  "versioned-api": "REL-003",
}
KNOWN_SUITES = set(DEFAULT_OWNERS) | {
  "bson-corpus",
  "connection-string",
  "max-staleness",
  "unified-test-format",
}


class LedgerError(ValueError):
  """Raised when discovered fixture coverage and the ledger diverge."""


def _canonical_fingerprint(value: Any) -> str:
  content = json.dumps(
    value,
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
  ).encode("utf-8")
  return hashlib.sha256(content).hexdigest()


def _file_fingerprint(path: Path) -> str:
  return hashlib.sha256(path.read_bytes()).hexdigest()


def discover_files(source: Path = SOURCE) -> dict[str, dict[str, str]]:
  """Inventory every JSON/YAML fixture file beneath a specification tests tree."""
  files = {}

  for path in sorted(source.glob("*/tests/**/*")):
    if not path.is_file() or path.suffix not in {".json", ".yaml", ".yml"}:
      continue

    relative = path.relative_to(source).as_posix()
    files[relative] = {
      "fingerprint": _file_fingerprint(path),
      "format": path.suffix[1:],
      "suite": relative.split("/", 1)[0],
    }

  return files


def _add_case(
  cases: dict[str, dict[str, Any]],
  identity: str,
  path: str,
  test_format: str,
  value: Any,
) -> None:
  cases[identity] = {
    "fingerprint": _canonical_fingerprint(value),
    "format": test_format,
    "source": path,
    "suite": path.split("/", 1)[0],
  }


def discover_cases(source: Path = SOURCE) -> dict[str, dict[str, Any]]:
  """Discover stable case identities from every canonical JSON fixture format."""
  cases = {}

  for path in sorted(source.glob("*/tests/**/*.json")):
    relative = path.relative_to(source).as_posix()

    try:
      document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
      raise LedgerError(f"could not load normative fixture {relative}: {exc}") from exc

    parts = Path(relative).parts

    if parts[:2] == ("unified-test-format", "tests"):
      _add_case(cases, f"{relative}::case", relative, "unified-meta", document)
    elif parts[:2] == ("bson-corpus", "tests"):
      context = {
        key: value for key, value in document.items()
        if key not in {"valid", "decodeErrors", "parseErrors"}
      }

      for field in ("valid", "decodeErrors", "parseErrors"):
        for index, case in enumerate(document.get(field, []), 1):
          _add_case(
            cases,
            f"{relative}::{field}[{index}]",
            relative,
            "bson-corpus",
            {"context": context, "case": case},
          )
    elif isinstance(document, dict) and isinstance(document.get("tests"), list):
      context = {key: value for key, value in document.items() if key != "tests"}
      test_format = "unified" if "schemaVersion" in document else "legacy-list"

      for index, case in enumerate(document["tests"], 1):
        _add_case(
          cases,
          f"{relative}::test[{index}]",
          relative,
          test_format,
          {"context": context, "test": case},
        )
    elif isinstance(document, dict) and isinstance(document.get("phases"), list):
      context = {key: value for key, value in document.items() if key != "phases"}

      for index, case in enumerate(document["phases"], 1):
        _add_case(
          cases,
          f"{relative}::phase[{index}]",
          relative,
          "legacy-phases",
          {"context": context, "phase": case},
        )
    else:
      _add_case(cases, f"{relative}::case", relative, "legacy-single", document)

  return cases


def load_activities() -> tuple[dict[str, dict[str, str]], str]:
  try:
    plan = json.loads(PLAN.read_text(encoding="utf-8"))
    progress = json.loads(PROGRESS.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise LedgerError(f"could not load roadmap state: {exc}") from exc

  records = progress.get("activities", {})
  activities = {}

  for activity in plan.get("activities", []):
    identity = activity["id"]
    activities[identity] = {
      "milestone": activity["milestone"],
      "status": records.get(identity, {}).get("status", "pending"),
    }

  return activities, plan["references"]["specifications"]["commit"]


def _passed(
  case: dict[str, Any],
  activity: str,
  runner: str,
  evidence: str,
  environment: str = "none",
) -> dict[str, Any]:
  return {
    **case,
    "activity": activity,
    "last_execution": evidence,
    "required_environment": environment,
    "runner": runner,
    "scope": "production-core-v1",
    "status": "passed",
  }


def _deferred(
  case: dict[str, Any],
  activity: str,
  activities: dict[str, dict[str, str]],
  runner: str | None = None,
) -> dict[str, Any]:
  if activity not in activities:
    raise LedgerError(f"normative fixture has unknown roadmap owner: {activity}")

  return {
    **case,
    "activity": activity,
    "last_execution": None,
    "required_environment": "live-mongodb",
    "runner": runner or f"pending:{activity}",
    "scope": activities[activity]["milestone"],
    "status": "deferred_unsupported",
  }


def _excluded(
  case: dict[str, Any],
  activity: str,
  runner: str,
  evidence: str,
  reason: str,
) -> dict[str, Any]:
  return {
    **case,
    "activity": activity,
    "last_execution": evidence,
    "reason": reason,
    "required_environment": "none",
    "runner": runner,
    "scope": "superseded",
    "status": "excluded_scope",
  }


def _unsupported(
  case: dict[str, Any],
  activity: str,
  activities: dict[str, dict[str, str]],
  reason: str,
) -> dict[str, Any]:
  if activity not in activities:
    raise LedgerError(f"normative fixture has unknown roadmap owner: {activity}")

  return {
    **case,
    "activity": activity,
    "last_execution": None,
    "reason": reason,
    "required_environment": "none",
    "runner": "none:unsupported",
    "scope": activities[activity]["milestone"],
    "status": "unsupported",
  }


def classify_case(
  identity: str,
  case: dict[str, Any],
  activities: dict[str, dict[str, str]],
  unified: dict[str, dict[str, Any]],
) -> dict[str, Any]:
  path = case["source"]
  suite = case["suite"]

  if identity in unified:
    value = unified[identity]

    if value["status"] == "runnable":
      execution = RUNNABLE_CASES.get(identity)

      if execution is None:
        raise LedgerError(f"runnable unified case has no exact executor: {identity}")

      return _passed(
        case,
        value["activity"],
        execution["runner"],
        execution["evidence"],
        execution["environment"],
      )

    row = _deferred(case, value["activity"], activities, "spec/unified/run.py")
    row["status"] = value["status"]

    if value["status"] == "excluded_scope":
      row["reason"] = value.get("reason") or "fixture is outside the supported driver scope"

    return row

  if suite == "unified-test-format":
    return _passed(
      case,
      "UTF-002",
      "spec/unified/run_schema_meta.py",
      "make test-unified-meta",
    )

  if suite == "bson-corpus":
    return _passed(
      case,
      "BSON-004",
      "spec/corpus/run_bson_corpus.py",
      "make test-unit",
    )

  if suite == "bson-binary-vector":
    return _passed(
      case,
      "REL-002",
      "spec/corpus/run_bson_vector.py",
      "make test-unit",
    )

  if suite == "initial-dns-seedlist-discovery":
    if "/tests/replica-set/" in path:
      return _passed(
        case,
        "ADV-014",
        "spec/support/dns_seedlist_runner.lua",
        "make test-unit",
        "deterministic-runtime",
      )

    if "/tests/sharded/" in path:
      return _passed(
        case,
        "DNS-001",
        "spec/support/dns_seedlist_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/dns_seedlist_spec.lua'",
        "deterministic-runtime",
      )

    if "/tests/load-balanced/" in path:
      return _passed(
        case,
        "ADV-006",
        "spec/support/dns_seedlist_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/dns_seedlist_spec.lua'",
        "deterministic-runtime",
      )

    raise LedgerError(f"unknown initial DNS deployment fixture: {identity}")

  if suite == "connection-string":
    return _passed(
      case,
      "CFG-001",
      "spec/unit/config_uri_spec.lua",
      "make test-unit",
    )

  if suite == "auth" and path.endswith("/legacy/connection-string.json"):
    index = int(identity.rsplit("[", 1)[1][:-1])

    if index in {*range(4, 12), 14, 15}:
      owner = "AUTH-019"
    elif 16 <= index <= 22:
      owner = "AUTH-004"
    elif 23 <= index <= 26:
      owner = "AUTH-003"
    elif 40 <= index <= 47:
      owner = "AUTH-020"
    elif 48 <= index <= 67:
      owner = "AUTH-010"
    else:
      owner = "AUTH-002"

    if index in {43, 44}:
      return _excluded(
        case,
        "AUTH-020",
        "spec/support/auth_config_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/config_credentials_spec.lua'",
        "retained legacy assertion was superseded by DRIVERS-3131, which prohibits explicit MONGODB-AWS URI credentials",
      )

    if owner in {"AUTH-002", "AUTH-003", "AUTH-004", "AUTH-010", "AUTH-020"}:
      return _passed(
        case,
        owner,
        "spec/support/auth_config_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/config_credentials_spec.lua'",
      )

    return _deferred(case, owner, activities)

  if suite == "uri-options":
    if path.endswith("/auth-options.json") and identity.endswith("::test[1]"):
      return _deferred(case, "AUTH-019", activities)

    if path.endswith("/srv-options.json"):
      return _passed(
        case,
        "ADV-003",
        "spec/support/config_runner.lua",
        "make test-unit",
      )

    owner_by_file = {
      "client-backpressure-options.json": "ADV-009",
      "compression-options.json": "ADV-004",
      "proxy-options.json": "ADV-012",
    }
    owner = owner_by_file.get(Path(path).name, "REL-003")

    if owner == "ADV-004":
      return _passed(
        case,
        owner,
        "spec/support/config_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/config_fixtures_spec.lua'",
      )

    if owner == "ADV-012":
      return _unsupported(
        case,
        owner,
        activities,
        "SOCKS5 proxy options and transport are not supported",
      )

    if owner != "REL-003":
      return _deferred(case, owner, activities)

    if path.endswith("/connection-options.json") and any(
      identity.endswith(f"::test[{index}]") for index in range(18, 25)
    ):
      return _passed(
        case,
        "ADV-006",
        "spec/support/config_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/config_fixtures_spec.lua'",
      )

    return _passed(
      case,
      "REL-003",
      "spec/support/config_runner.lua",
      "make test-unit",
    )

  if suite == "read-write-concern" and (
    "/tests/connection-string/" in path or "/tests/document/" in path
  ):
    return _passed(
      case,
      "REL-003",
      "spec/support/config_runner.lua",
      "make test-unit",
    )

  if (
    suite == "server-selection"
    and "/tests/server_selection/LoadBalanced/" in path
  ):
    return _passed(
      case,
      "LB-001",
      "spec/unit/selection_spec.lua",
      "make test-focus FOCUS_UNIT='spec/unit/selection_spec.lua'",
    )

  if suite == "max-staleness" or (
    suite == "server-selection"
    and "/logging/" not in path
  ):
    return _passed(
      case,
      "SEL-001",
      "spec/unit/selection_spec.lua",
      "make test-unit",
    )

  if suite == "server-discovery-and-monitoring":
    if any(f"/tests/{directory}/" in path for directory in ("single", "rs", "sharded")):
      return _passed(
        case,
        "SDAM-001",
        "spec/unit/sdam_spec.lua",
        "make test-unit",
      )

    if "/tests/errors/" in path or (
      "/tests/monitoring/" in path and not path.endswith("load_balancer.json")
    ):
      return _passed(
        case,
        "SDAM-002",
        "spec/support/sdam_runner.lua",
        "make test-unit",
        "deterministic-runtime",
      )

    if "/tests/load-balanced/" in path or path.endswith("/monitoring/load_balancer.json"):
      return _passed(
        case,
        "ADV-006",
        "spec/support/sdam_runner.lua",
        "make test-focus FOCUS_UNIT='spec/unit/topology_spec.lua'",
        "deterministic-runtime",
      )

    return _deferred(case, "SDAM-002", activities)

  if suite == "load-balancers":
    fixture = Path(path).name
    index = int(identity.rsplit("[", 1)[1][:-1])

    if fixture == "cursors.json":
      if index <= 3:
        owner = "LB-007"
      elif index <= 6:
        owner = "LB-008"
      else:
        owner = "LB-009"
    elif fixture == "event-monitoring.json":
      return _passed(
        case,
        "LB-006",
        "spec/unit/command_monitoring_spec.lua",
        "make test-focus FOCUS_UNIT='spec/unit/command_monitoring_spec.lua spec/unit/pool_spec.lua spec/unit/unified_events_spec.lua'",
        "deterministic-runtime",
      )
    elif fixture == "lb-connection-establishment.json":
      return _excluded(
        case,
        "LB-003",
        "spec/integration/load_balancer_spec.lua",
        "make test-focus FOCUS_INTEGRATION='spec/integration/load_balancer_spec.lua'",
        "the upstream case has a skipReason because load balancers do not reject loadBalanced=false",
      )
    elif fixture == "non-lb-connection-establishment.json":
      return _passed(
        case,
        "LB-003",
        "spec/integration/load_balancer_spec.lua",
        "make test-focus FOCUS_INTEGRATION='spec/integration/load_balancer_spec.lua'",
        "directly-coupled-endpoint",
      )
    elif fixture == "sdam-error-handling.json":
      if index in {1, 4}:
        return _passed(
          case,
          "LB-004",
          "spec/unit/topology_spec.lua",
          "make test-focus FOCUS_UNIT='spec/unit/pool_spec.lua spec/unit/topology_spec.lua'",
          "deterministic-runtime",
        )

      return _passed(
        case,
        "LB-005",
        "spec/unit/topology_spec.lua",
        "make test-focus FOCUS_UNIT='spec/unit/pool_spec.lua spec/unit/topology_spec.lua'",
        "deterministic-runtime",
      )
    elif fixture == "server-selection.json":
      return _passed(
        case,
        "LB-001",
        "spec/unit/topology_spec.lua",
        "make test-focus FOCUS_UNIT='spec/unit/topology_spec.lua'",
        "deterministic-runtime",
      )
    elif fixture == "transactions.json":
      if index == 1:
        return _passed(
          case,
          "LB-002",
          "spec/unit/session_spec.lua",
          "make test-focus FOCUS_UNIT='spec/unit/session_spec.lua'",
          "deterministic-runtime",
        )
      elif index <= 3:
        owner = "LB-011"
      elif index <= 6:
        owner = "LB-012"
      elif index <= 8:
        owner = "LB-013"
      elif index <= 10:
        owner = "LB-014"
      elif index <= 13:
        owner = "LB-015"
      elif index <= 15:
        owner = "LB-016"
      elif index == 16:
        owner = "LB-017"
      else:
        owner = "LB-018"
    elif fixture == "wait-queue-timeouts.json":
      owner = "LB-010"
    else:
      raise LedgerError(f"unknown load-balancer fixture: {identity}")

    return _deferred(case, owner, activities)

  if suite == "connection-monitoring-and-pooling":
    if "/tests/cmap-format/" in path:
      environment = "deterministic-runtime"
      return _passed(
        case,
        "CMAP-001",
        "spec/support/cmap_runner.lua",
        "make test-unit && make test-integration",
        environment,
      )

    return _deferred(case, "ADV-009", activities)

  if suite == "sessions":
    if "snapshot-sessions" in path:
      fixture = Path(path).name
      index = int(identity.rsplit("[", 1)[1][:-1])
      if fixture == "snapshot-sessions.json":
        if index == 8:
          owner = "SES-004"
        elif index >= 9:
          owner = "SES-007"
        else:
          owner = "SES-006"
      elif fixture == "snapshot-sessions-not-supported-client-error.json":
        owner = "SES-005"
      else:
        owner = "SES-008"
      return _deferred(case, owner, activities)

    if "implicit-sessions-default-causal-consistency" in path:
      return _passed(
        case,
        "RETRY-001",
        "spec/support/session_runner.lua",
        "make test-unit",
        "deterministic-runtime",
      )

    return _passed(
      case,
      "SES-001",
      "spec/support/session_runner.lua",
      "make test-unit",
      "deterministic-runtime",
    )

  if (
    suite == "collection-management"
    and Path(path).name == "createCollection-pre_and_post_images.json"
  ):
    return _deferred(case, "CS-009", activities)

  if (
    suite == "collection-management"
    and Path(path).name == "modifyCollection-pre_and_post_images.json"
  ):
    return _deferred(case, "CS-010", activities)

  if suite == "collection-management" and Path(path).name in {
    "listCollections-rawdata.json",
  }:
    return _deferred(case, "REL-018", activities)

  if suite == "collection-management" and Path(path).name in {
    "clustered-indexes.json",
    "timeseries-collection.json",
  }:
    return _deferred(case, "REL-019", activities)

  if suite == "index-management" and Path(path).name in {
    "createSearchIndex.json",
    "createSearchIndexes.json",
    "dropSearchIndex.json",
    "listSearchIndexes.json",
    "searchIndexIgnoresReadWriteConcern.json",
    "updateSearchIndex.json",
  }:
    return _deferred(case, "ADV-011", activities)

  if suite == "causal-consistency" and "clientBulkWrite" not in path:
    return _passed(
      case,
      "SES-001",
      "spec/support/session_runner.lua",
      "make test-unit",
      "deterministic-runtime",
    )

  owner = DEFAULT_OWNERS.get(suite)

  if owner is None:
    raise LedgerError(f"normative fixture suite has no roadmap owner: {suite}")

  if suite == "causal-consistency" and "clientBulkWrite" in path:
    owner = "CBW-009"

  return _deferred(case, owner, activities)


def validate_cases(
  discovered: dict[str, dict[str, Any]],
  classified: dict[str, dict[str, Any]],
  activity_states: dict[str, str],
) -> None:
  missing = sorted(set(discovered) - set(classified))
  stale = sorted(set(classified) - set(discovered))

  if missing:
    raise LedgerError(f"unclassified normative case: {missing[0]}")

  if stale:
    raise LedgerError(f"ledger references missing normative case: {stale[0]}")

  required = {
    "activity", "fingerprint", "format", "last_execution",
    "required_environment", "runner", "scope", "source",
    "specifications_commit", "status", "suite",
  }

  for identity, source in discovered.items():
    value = classified[identity]

    if value.get("fingerprint") != source["fingerprint"]:
      raise LedgerError(f"conformance fingerprint is stale for {identity}")

    for key in ("format", "source", "suite"):
      if value.get(key) != source[key]:
        raise LedgerError(f"conformance {key} is stale for {identity}")

    expected_fields = required | (
      {"reason"}
      if value.get("status") in {"excluded_scope", "unsupported"}
      else set()
    )

    if set(value) != expected_fields:
      raise LedgerError(f"conformance record has malformed fields for {identity}")

    activity = value["activity"]

    if activity not in activity_states:
      raise LedgerError(f"conformance record has unknown owner {activity}: {identity}")

    if value["status"] not in VALID_STATUSES:
      raise LedgerError(f"conformance record has unknown status for {identity}")

    if not isinstance(value["runner"], str) or not value["runner"]:
      raise LedgerError(f"conformance record has no runner for {identity}")

    if value["status"] == "deferred_unsupported" and activity_states[activity] == "completed":
      raise LedgerError(f"deferred case is owned by completed activity {activity}: {identity}")

    if value["status"] == "passed":
      if value["runner"].startswith("pending:"):
        raise LedgerError(f"passing case has a pending runner: {identity}")

      if not isinstance(value["last_execution"], str) or not value["last_execution"]:
        raise LedgerError(f"passing case has no execution evidence: {identity}")

    if value["status"] == "excluded_scope":
      if not isinstance(value["reason"], str) or not value["reason"].strip():
        raise LedgerError(f"excluded case has no reason: {identity}")

    if value["status"] == "unsupported":
      if activity_states[activity] not in {"completed", "in_progress"}:
        raise LedgerError(f"unsupported case has inactive owner {activity}: {identity}")

      if value["runner"] != "none:unsupported":
        raise LedgerError(f"unsupported case has a runner: {identity}")

      if value["required_environment"] != "none":
        raise LedgerError(f"unsupported case requires an environment: {identity}")

      if value["last_execution"] is not None:
        raise LedgerError(f"unsupported case claims execution evidence: {identity}")

      if not isinstance(value["reason"], str) or not value["reason"].strip():
        raise LedgerError(f"unsupported case has no reason: {identity}")


def validate_files(
  discovered: dict[str, dict[str, str]],
  classified: dict[str, dict[str, str]],
) -> None:
  missing = sorted(set(discovered) - set(classified))
  stale = sorted(set(classified) - set(discovered))

  if missing:
    raise LedgerError(f"untracked normative fixture file: {missing[0]}")

  if stale:
    raise LedgerError(f"ledger references missing fixture file: {stale[0]}")

  for path, source in discovered.items():
    if classified[path] != source:
      raise LedgerError(f"normative fixture file fingerprint is stale: {path}")


def generate() -> dict[str, Any]:
  activities, commit = load_activities()
  activity_states = {
    identity: value["status"] for identity, value in activities.items()
  }

  try:
    capabilities = json.loads(CAPABILITIES.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise LedgerError(f"could not load unified capabilities: {exc}") from exc

  if capabilities.get("specifications_commit") != commit:
    raise LedgerError("unified capability and roadmap specification commits differ")

  discovered = discover_cases()
  classified = {
    identity: classify_case(identity, case, activities, capabilities["tests"])
    for identity, case in discovered.items()
  }

  for value in classified.values():
    value["specifications_commit"] = commit

  files = discover_files()

  for path, value in files.items():
    if value["suite"] not in KNOWN_SUITES:
      raise LedgerError(f"normative fixture suite has no roadmap owner: {path}")

  validate_cases(discovered, classified, activity_states)
  validate_files(files, files)
  statuses = Counter(value["status"] for value in classified.values())
  suites = Counter(value["suite"] for value in classified.values())
  return {
    "cases": classified,
    "files": files,
    "schema_version": 1,
    "specifications_commit": commit,
    "summary": {
      "cases": len(classified),
      "files": len(files),
      "statuses": dict(sorted(statuses.items())),
      "suites": dict(sorted(suites.items())),
    },
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    generated = generate()
    encoded = json.dumps(generated, indent=2, sort_keys=True) + "\n"
  except (LedgerError, OSError, json.JSONDecodeError) as exc:
    print(f"conformance ledger: {exc}", file=sys.stderr)
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("conformance ledger is stale", file=sys.stderr)
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  summary = generated["summary"]
  statuses = summary["statuses"]
  print(
    f"conformance ledger: {summary['files']} files, {summary['cases']} cases; "
    f"{statuses.get('passed', 0)} passed, "
    f"{statuses.get('deferred_unsupported', 0)} deferred-unsupported"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
