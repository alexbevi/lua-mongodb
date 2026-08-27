#!/usr/bin/env python3
"""Discover and report pinned MongoDB unified test fixture capabilities."""

from __future__ import annotations

import argparse
from contextlib import ExitStack, contextmanager
import fnmatch
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any
from urllib.parse import urlsplit, urlunsplit


ROOT = Path(__file__).resolve().parents[2]

if str(ROOT) not in sys.path:
  sys.path.insert(0, str(ROOT))

from spec import sharded_environment as sharded_cluster

DEFAULT_SOURCE = ROOT / "planning" / "specifications" / "source"
DEFAULT_MANIFEST = ROOT / "spec" / "unified" / "capabilities.json"
DEFAULT_PLAN = ROOT / "planning" / "plan.json"
DEFAULT_PROGRESS = ROOT / "planning" / "progress.json"
DEFAULT_EXECUTOR = ROOT / "spec" / "unified" / "execute.lua"
DEFAULT_EXECUTOR_REGISTRY = ROOT / "spec" / "unified" / "executors.json"
CSOT_FIXTURE_PREFIX = "client-side-operations-timeout/"
AUTHENTICATED_STANDALONE_ENVIRONMENT = "live-authenticated-standalone"
AUTHENTICATED_STANDALONE_URI = "MONGODB_UNIFIED_AUTH_URI"
AUTHENTICATED_STANDALONE_VERSION = "MONGODB_UNIFIED_AUTH_SERVER_VERSION"
AUTHENTICATED_REPLICA_SET_ENVIRONMENT = "live-authenticated-replicaset"
AUTHENTICATED_REPLICA_SET_URI = "MONGODB_UNIFIED_AUTH_REPLICA_SET_URI"
AUTHENTICATED_REPLICA_SET_VERSION = (
  "MONGODB_UNIFIED_AUTH_REPLICA_SET_SERVER_VERSION"
)
LOAD_BALANCED_ENVIRONMENT = "live-load-balanced"
LOAD_BALANCED_URI = "MONGODB_UNIFIED_LOAD_BALANCED_URI"
LOAD_BALANCED_VERSION = "MONGODB_UNIFIED_LOAD_BALANCED_SERVER_VERSION"
MACOS_CI_TIMING_SENSITIVE_CSOT = frozenset({
  "client-side-operations-timeout/tests/bulkWrite.json::test[1]",
  "client-side-operations-timeout/tests/change-streams.json::test[4]",
  "client-side-operations-timeout/tests/change-streams.json::test[5]",
  "client-side-operations-timeout/tests/change-streams.json::test[6]",
  "client-side-operations-timeout/tests/close-cursors.json::test[1]",
  "client-side-operations-timeout/tests/close-cursors.json::test[2]",
  "client-side-operations-timeout/tests/command-execution.json::test[1]",
  "client-side-operations-timeout/tests/command-execution.json::test[2]",
  "client-side-operations-timeout/tests/command-execution.json::test[3]",
  "client-side-operations-timeout/tests/gridfs-download.json::test[4]",
  "client-side-operations-timeout/tests/non-tailable-cursors.json::test[2]",
  "client-side-operations-timeout/tests/non-tailable-cursors.json::test[3]",
  "client-side-operations-timeout/tests/non-tailable-cursors.json::test[5]",
  "client-side-operations-timeout/tests/runCursorCommand.json::test[3]",
  "client-side-operations-timeout/tests/tailable-awaitData.json::test[9]",
  "client-side-operations-timeout/tests/tailable-awaitData.json::test[10]",
  "client-side-operations-timeout/tests/tailable-awaitData.json::test[12]",
  "client-side-operations-timeout/tests/tailable-non-awaitData.json::test[3]",
})
LINUX_CI_FOCUSED_CSOT = frozenset({
  "client-side-operations-timeout/tests/command-execution.json::test[3]",
})
VALID_STATUSES = {"deferred_unsupported", "excluded_scope", "runnable"}
REPORT_VERSION = 2
SLOWEST_FIXTURE_GROUP_LIMIT = 10
IDENTITY_SHARDED_FIXTURES = frozenset({
  "transactions/tests/unified/mongos-pin-auto.json",
})
PROCESS_ISOLATED_FIXTURES = frozenset({
  "client-side-operations-timeout/tests/command-execution.json",
})
KNOWN_REQUIREMENT_KEYS = {
  "arguments",
  "entities",
  "events",
  "has_outcome",
  "logs",
  "match_operators",
  "operations",
  "special_operations",
  "topologies",
}
KNOWN_ENTITIES = {
  "bucket",
  "client",
  "clientEncryption",
  "collection",
  "database",
  "session",
  "thread",
}
KNOWN_MATCH_OPERATORS = {
  "$$exists",
  "$$hexBytes",
  "$$lte",
  "$$matchAsDocument",
  "$$matchAsRoot",
  "$$matchesEntity",
  "$$matchesHexBytes",
  "$$sessionLsid",
  "$$type",
  "$$unsetOrMatches",
}
KNOWN_OPERATIONS = {
  "abortTransaction", "addKeyAltName", "aggregate", "appendMetadata",
  "bulkWrite", "clientBulkWrite", "close", "commitTransaction", "count",
  "countDocuments", "createChangeStream", "createCollection",
  "createCommandCursor", "createDataKey", "createFindCursor", "createIndex",
  "createSearchIndex", "createSearchIndexes", "decrypt",
  "delete", "deleteByName", "deleteKey", "deleteMany", "deleteOne", "distinct", "download",
  "downloadByName", "drop", "dropCollection", "dropIndex", "dropIndexes",
  "dropSearchIndex", "encrypt", "endSession",
  "estimatedDocumentCount", "find", "findOne", "findOneAndDelete",
  "findOneAndReplace", "findOneAndUpdate", "getKey", "getKeyByAltName",
  "getKeys", "getSnapshotTime", "insertMany", "insertOne", "iterateOnce",
  "iterateUntilDocumentOrError", "listCollectionNames",
  "listCollectionObjects", "listCollections", "listDatabaseNames",
  "listDatabaseObjects", "listDatabases", "listIndexNames", "listIndexes",
  "listSearchIndexes",
  "mapReduce", "modifyCollection", "removeKeyAltName", "rename", "renameByName",
  "replaceOne", "rewrapManyDataKey", "runCommand", "runCursorCommand",
  "startTransaction", "updateMany", "updateOne", "updateSearchIndex", "upload",
  "withTransaction",
}
KNOWN_SPECIAL_OPERATIONS = {
  "assertCollectionExists", "assertCollectionNotExists", "assertEventCount",
  "assertIndexExists", "assertIndexNotExists", "assertNumberConnectionsCheckedOut",
  "assertSameLsidOnLastTwoCommands", "assertSessionPinned",
  "assertSessionTransactionState", "assertSessionUnpinned", "assertTopologyType",
  "createEntities", "failPoint", "recordTopologyDescription", "runOnThread",
  "targetedFailPoint", "wait", "waitForEvent", "waitForPrimaryChange",
  "waitForThread",
}
KNOWN_EVENTS = {
  "commandFailedEvent", "commandStartedEvent", "commandSucceededEvent",
  "connectionCheckOutStartedEvent", "connectionCheckedInEvent",
  "connectionCheckedOutEvent", "connectionClosedEvent", "connectionCreatedEvent",
  "connectionReadyEvent", "poolClearedEvent", "serverDescriptionChangedEvent",
  "poolReadyEvent",
  "serverHeartbeatStartedEvent", "serverHeartbeatSucceededEvent",
  "topologyClosedEvent", "topologyDescriptionChangedEvent", "topologyOpeningEvent",
}
KNOWN_TOPOLOGIES = {
  "load-balanced", "replicaset", "sharded", "sharded-replicaset", "single",
}


class CapabilityError(ValueError):
  """Raised when fixture discovery and the capability manifest diverge."""


def _duration_ms(value: float, label: str) -> float:
  duration = round(value * 1000, 3)

  if not math.isfinite(duration) or duration < 0:
    raise CapabilityError(f"{label} duration must be a non-negative number")

  return duration


def _timing_report(
  setup_ms: float,
  total_ms: float,
  environments: dict[str, float],
  fixture_groups: list[dict[str, Any]],
) -> dict[str, Any]:
  groups = sorted(
    (dict(group) for group in fixture_groups),
    key=lambda group: (group["fixture"], group["environment"]),
  )
  slowest = sorted(
    (dict(group) for group in groups),
    key=lambda group: (
      -group["duration_ms"],
      group["fixture"],
      group["environment"],
    ),
  )[:SLOWEST_FIXTURE_GROUP_LIMIT]
  return {
    "environments": [
      {
        "duration_ms": round(duration_ms, 3),
        "environment": environment,
      }
      for environment, duration_ms in sorted(environments.items())
    ],
    "fixture_groups": groups,
    "setup_ms": round(setup_ms, 3),
    "slowest_fixture_groups": slowest,
    "total_ms": round(total_ms, 3),
  }


class ExecutionTimings:
  """Collect observational runner timings without changing conformance rows."""

  def __init__(self, clock: Any = time.perf_counter):
    self._clock = clock
    self._started = clock()
    self._setup_ms: float | None = None
    self._environments: dict[str, float] = {}
    self._fixture_groups: list[dict[str, Any]] = []

  def finish_setup(self) -> None:
    if self._setup_ms is None:
      self._setup_ms = _duration_ms(
        self._clock() - self._started,
        "unified setup",
      )

  @contextmanager
  def observe_environment(self, environment: str):
    started = self._clock()

    try:
      yield
    finally:
      duration_ms = _duration_ms(
        self._clock() - started,
        f"unified {environment} environment",
      )
      self._environments[environment] = (
        self._environments.get(environment, 0.0) + duration_ms
      )

  @contextmanager
  def observe_fixture_group(
    self,
    classifications: list[dict[str, Any]],
    environment: str,
  ):
    if not classifications:
      raise CapabilityError("cannot time an empty unified fixture group")

    fixture = classifications[0]["fixture"]
    started = self._clock()

    try:
      yield
    finally:
      self._fixture_groups.append({
        "duration_ms": _duration_ms(
          self._clock() - started,
          f"unified fixture group {fixture}",
        ),
        "environment": environment,
        "fixture": fixture,
        "tests": len(classifications),
      })

  def attach(self, report: dict[str, Any]) -> None:
    self.finish_setup()
    report["timings"] = _timing_report(
      self._setup_ms or 0.0,
      _duration_ms(self._clock() - self._started, "unified total"),
      self._environments,
      self._fixture_groups,
    )


class ExecutionProgress:
  """Emit flushed human diagnostics without changing report output."""

  def __init__(
    self,
    total_batches: int,
    stream: Any = None,
    clock: Any = time.perf_counter,
  ):
    if type(total_batches) is not int or total_batches < 0:
      raise CapabilityError("unified progress total must be a non-negative integer")

    self._clock = clock
    self._current = 0
    self._stream = stream or sys.stderr
    self._total = total_batches

  def start(
    self,
    classifications: list[dict[str, Any]],
    environment: str,
  ) -> tuple[int, float]:
    if not classifications:
      raise CapabilityError("cannot report an empty unified fixture group")

    self._current += 1
    fixture = classifications[0]["fixture"]
    print(
      f"unified progress: [{self._current}/{self._total}] start "
      f"{environment} {fixture} ({len(classifications)} tests)",
      file=self._stream,
      flush=True,
    )
    return self._current, self._clock()

  def finish(
    self,
    classifications: list[dict[str, Any]],
    environment: str,
    results: dict[str, tuple[str, str | None]],
    started: tuple[int, float],
  ) -> None:
    index, started_at = started
    fixture = classifications[0]["fixture"]
    counts = {
      "environment_skipped": 0,
      "failed": 0,
      "passed": 0,
    }

    for status, _ in results.values():
      if status in counts:
        counts[status] += 1

    duration_ms = _duration_ms(
      self._clock() - started_at,
      f"unified progress fixture group {fixture}",
    )
    print(
      f"unified progress: [{index}/{self._total}] done "
      f"{environment} {fixture} duration_ms={duration_ms:.3f} "
      f"passed={counts['passed']} "
      f"environment_skipped={counts['environment_skipped']} "
      f"failed={counts['failed']}",
      file=self._stream,
      flush=True,
    )


def discover_fixtures(source: Path, includes: list[str] | None = None) -> list[str]:
  """Return sorted source-relative unified JSON fixture paths."""
  if not source.is_dir():
    raise CapabilityError(f"unified specification source does not exist: {source}")

  patterns = includes or ["*"]
  fixtures = []

  for path in source.rglob("*.json"):
    relative = path.relative_to(source)
    parts = relative.parts

    is_unified_directory = len(parts) >= 4 and parts[-3:-1] == ("tests", "unified")
    is_csot_directory = (
      len(parts) == 3
      and parts[0] == "client-side-operations-timeout"
      and parts[1] == "tests"
    )
    is_release_directory = (
      len(parts) == 3 and parts[0] == "versioned-api" and parts[1] == "tests"
    ) or (
      len(parts) == 4
      and parts[0] == "read-write-concern"
      and parts[1:3] == ("tests", "operation")
    )
    is_management_directory = (
      len(parts) == 3
      and parts[0] in {"collection-management", "index-management"}
      and parts[1] == "tests"
    )
    is_gridfs_directory = (
      len(parts) == 3
      and parts[:2] == ("gridfs", "tests")
    )
    is_snapshot_session_fixture = (
      len(parts) == 3
      and parts[:2] == ("sessions", "tests")
      and parts[2].startswith("snapshot-sessions")
    )
    is_client_bulk_causal_fixture = relative.as_posix() == (
      "causal-consistency/tests/causal-consistency-clientBulkWrite.json"
    )
    is_security_monitoring_fixture = relative.as_posix() == (
      "command-logging-and-monitoring/tests/monitoring/redacted-commands.json"
    )
    is_command_monitoring_fixture = relative.as_posix() == (
      "command-logging-and-monitoring/tests/monitoring/command.json"
    )
    is_find_monitoring_fixture = relative.as_posix() == (
      "command-logging-and-monitoring/tests/monitoring/find.json"
    )
    is_insert_one_monitoring_fixture = relative.as_posix() == (
      "command-logging-and-monitoring/tests/monitoring/insertOne.json"
    )
    is_server_connection_id_monitoring_fixture = relative.as_posix() == (
      "command-logging-and-monitoring/tests/monitoring/server-connection-id.json"
    )
    is_command_lifecycle_logging_fixture = relative.as_posix() in {
      "command-logging-and-monitoring/tests/logging/command.json",
      "command-logging-and-monitoring/tests/logging/driver-connection-id.json",
      "command-logging-and-monitoring/tests/logging/no-handshake-messages.json",
      "command-logging-and-monitoring/tests/logging/no-heartbeat-messages.json",
      "command-logging-and-monitoring/tests/logging/operation-id.json",
      "command-logging-and-monitoring/tests/logging/redacted-commands.json",
      "command-logging-and-monitoring/tests/logging/server-connection-id.json",
      "command-logging-and-monitoring/tests/logging/service-id.json",
      "command-logging-and-monitoring/tests/logging/unacknowledged-write.json",
    }

    if not (
      is_unified_directory
      or is_csot_directory
      or is_release_directory
      or is_management_directory
      or is_gridfs_directory
      or is_snapshot_session_fixture
      or is_client_bulk_causal_fixture
      or is_security_monitoring_fixture
      or is_command_monitoring_fixture
      or is_find_monitoring_fixture
      or is_insert_one_monitoring_fixture
      or is_server_connection_id_monitoring_fixture
      or is_command_lifecycle_logging_fixture
    ):
      continue

    name = relative.as_posix()

    if any(fnmatch.fnmatchcase(name, pattern) for pattern in patterns):
      fixtures.append(name)

  return sorted(fixtures)


def _walk_requirements(value: Any, operators: set[str]) -> None:
  if isinstance(value, dict):
    for key, item in value.items():
      if key.startswith("$$"):
        operators.add(key)

      _walk_requirements(item, operators)
  elif isinstance(value, list):
    for item in value:
      _walk_requirements(item, operators)


def extract_requirements(document: dict[str, Any], test: dict[str, Any]) -> dict[str, Any]:
  entities = set()
  operations = set()
  special_operations = set()
  arguments = set()
  events = set()
  match_operators = set()
  topologies = set()

  for entity in document.get("createEntities", []):
    entities.update(entity)

  for operation in test.get("operations", []):
    name = operation["name"]

    if operation["object"] == "testRunner":
      special_operations.add(name)
    else:
      operations.add(name)

    arguments.update(f"{name}.{key}" for key in operation.get("arguments", {}))

    if name == "createEntities":
      for entity in operation.get("arguments", {}).get("entities", []):
        entities.update(entity)

  for expected in test.get("expectEvents", []):
    for event in expected.get("events", []):
      events.update(event)

  for requirement in document.get("runOnRequirements", []):
    topologies.update(requirement.get("topologies", []))

  for requirement in test.get("runOnRequirements", []):
    topologies.update(requirement.get("topologies", []))

  _walk_requirements(test, match_operators)
  return {
    "arguments": sorted(arguments),
    "entities": sorted(entities),
    "events": sorted(events),
    "has_outcome": "outcome" in test,
    "logs": bool(test.get("expectLogMessages")),
    "match_operators": sorted(match_operators),
    "operations": sorted(operations),
    "special_operations": sorted(special_operations),
    "topologies": sorted(topologies),
  }


def discover_tests(source: Path, includes: list[str] | None = None) -> list[dict[str, Any]]:
  """Return stable identities, fingerprints, and requirements for every test."""
  result = []

  for relative in discover_fixtures(source, includes):
    path = source / relative

    try:
      document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
      raise CapabilityError(f"could not load unified fixture {relative}: {exc}") from exc

    context = {
      key: value for key, value in document.items()
      if key != "tests"
    }

    for index, test in enumerate(document.get("tests", []), 1):
      identity = f"{relative}::test[{index}]"
      content = json.dumps(
        {"context": context, "test": test},
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
      ).encode("utf-8")
      result.append({
        "description": test.get("description"),
        "fingerprint": hashlib.sha256(content).hexdigest(),
        "fixture": relative,
        "id": identity,
        "index": index,
        "requirements": extract_requirements(document, test),
      })

  return result


def load_manifest(path: Path) -> dict[str, Any]:
  try:
    manifest = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load capability manifest {path}: {exc}") from exc

  if manifest.get("schema_version") != 2:
    raise CapabilityError("capability manifest schema_version must be 2")

  tests = manifest.get("tests")

  if not isinstance(tests, dict):
    raise CapabilityError("capability manifest tests must be an object")

  if not isinstance(manifest.get("ratchets"), dict):
    raise CapabilityError("capability manifest ratchets must be an object")

  return manifest


def load_activity_states(plan_path: Path, progress_path: Path) -> dict[str, str]:
  try:
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    progress = json.loads(progress_path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load roadmap state: {exc}") from exc

  activities = plan.get("activities")

  if not isinstance(activities, list):
    raise CapabilityError("roadmap activities must be an array")

  ids = [value.get("id") for value in activities if isinstance(value, dict)]

  if len(set(ids)) != len(activities) or not all(isinstance(value, str) for value in ids):
    raise CapabilityError("every roadmap activity must have a unique string id")

  records = progress.get("activities")

  if not isinstance(records, dict):
    raise CapabilityError("roadmap progress activities must be an object")

  return {
    activity: records.get(activity, {}).get("status", "pending")
    for activity in ids
  }


def _validate_requirement_values(identity: str, requirements: dict[str, Any]) -> None:
  unknown_keys = set(requirements) - KNOWN_REQUIREMENT_KEYS

  if unknown_keys:
    raise CapabilityError(
      f"classification for {identity} has unknown requirement: {sorted(unknown_keys)[0]}"
    )

  known_values = {
    "entities": KNOWN_ENTITIES,
    "events": KNOWN_EVENTS,
    "match_operators": KNOWN_MATCH_OPERATORS,
    "operations": KNOWN_OPERATIONS,
    "special_operations": KNOWN_SPECIAL_OPERATIONS,
    "topologies": KNOWN_TOPOLOGIES,
  }

  for key, allowed in known_values.items():
    values = requirements.get(key)

    if not isinstance(values, list) or values != sorted(set(values)):
      raise CapabilityError(f"classification for {identity} has malformed {key}")

    unknown = set(values) - allowed

    if unknown:
      raise CapabilityError(
        f"classification for {identity} has unknown {key}: {sorted(unknown)[0]}"
      )

  arguments = requirements.get("arguments")

  if not isinstance(arguments, list) or arguments != sorted(set(arguments)):
    raise CapabilityError(f"classification for {identity} has malformed arguments")

  if not isinstance(requirements.get("has_outcome"), bool):
    raise CapabilityError(f"classification for {identity} has malformed has_outcome")

  if not isinstance(requirements.get("logs"), bool):
    raise CapabilityError(f"classification for {identity} has malformed logs")


def classify_tests(
  discovered: list[dict[str, Any]],
  classifications: dict[str, Any],
  activity_states: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
  """Validate exact per-test coverage and return normalized classifications."""
  discovered_by_id = {value["id"]: value for value in discovered}
  discovered_set = set(discovered_by_id)
  classified_set = set(classifications)
  missing = sorted(discovered_set - classified_set)
  stale = sorted(classified_set - discovered_set)

  if missing:
    raise CapabilityError(f"unclassified unified test: {missing[0]}")

  if stale:
    raise CapabilityError(f"manifest references undiscovered unified test: {stale[0]}")

  result = []

  for discovered_test in discovered:
    identity = discovered_test["id"]
    value = classifications[identity]

    if not isinstance(value, dict):
      raise CapabilityError(f"classification for {identity} must be an object")

    status = value.get("status")
    reason = value.get("reason")
    activity = value.get("activity")
    fingerprint = value.get("fingerprint")
    requirements = value.get("requirements")

    if status not in VALID_STATUSES:
      raise CapabilityError(f"classification for {identity} has unknown status: {status}")

    if status != "runnable" and (not isinstance(reason, str) or not reason.strip()):
      raise CapabilityError(f"deferred unified test {identity} must have a reason")

    if status == "runnable" and reason is not None:
      raise CapabilityError(f"runnable unified test {identity} must not have a reason")

    if not isinstance(activity, str) or not activity:
      raise CapabilityError(f"classification for {identity} must name an activity")

    if fingerprint != discovered_test["fingerprint"]:
      raise CapabilityError(f"classification fingerprint is stale for {identity}")

    if requirements != discovered_test["requirements"]:
      raise CapabilityError(f"classification requirements are stale for {identity}")

    _validate_requirement_values(identity, requirements)

    if activity_states is not None and activity not in activity_states:
      raise CapabilityError(
        f"classification for {identity} has unknown activity owner: {activity}"
      )

    if (
      status == "deferred_unsupported"
      and activity_states is not None
      and activity_states[activity] == "completed"
    ):
      raise CapabilityError(
        f"deferred unified test {identity} is owned by completed activity {activity}"
      )

    row = {
      "activity": activity,
      "description": discovered_test["description"],
      "fingerprint": fingerprint,
      "fixture": discovered_test["fixture"],
      "id": identity,
      "index": discovered_test["index"],
      "requirements": requirements,
      "status": status,
    }

    if reason is not None:
      row["reason"] = reason

    result.append(row)

  return result


def select_classifications(
  classifications: list[dict[str, Any]],
  includes: list[str] | None,
) -> list[dict[str, Any]]:
  patterns = includes or ["*"]
  return [
    value for value in classifications
    if any(
      fnmatch.fnmatchcase(value["fixture"], pattern)
      or fnmatch.fnmatchcase(value["id"], pattern)
      for pattern in patterns
    )
  ]


def fixture_shard(fixture: str, count: int) -> int:
  """Return a stable shard index derived only from the fixture identity."""
  if type(count) is not int or count <= 0:
    raise CapabilityError("shard count must be a positive integer")

  digest = hashlib.sha256(fixture.encode("utf-8")).digest()
  return int.from_bytes(digest[:8], "big") % count


def classification_shard(classification: dict[str, Any], count: int) -> int:
  """Return a stable shard while splitting measured oversized fixtures."""
  fixture = classification["fixture"]

  if fixture not in IDENTITY_SHARDED_FIXTURES:
    return fixture_shard(fixture, count)

  index = classification.get("index")

  if type(index) is not int or index <= 0:
    raise CapabilityError(
      f"identity-sharded fixture classification has no valid index: {fixture}"
    )

  if type(count) is not int or count <= 0:
    raise CapabilityError("shard count must be a positive integer")

  return (index - 1) % count


def select_shard(
  classifications: list[dict[str, Any]],
  count: int,
  index: int,
) -> list[dict[str, Any]]:
  """Select one deterministic, non-overlapping conformance shard."""
  if type(index) is not int or index < 0 or index >= count:
    raise CapabilityError("shard index must be between zero and count minus one")

  return [
    classification for classification in classifications
    if classification_shard(classification, count) == index
  ]


def build_inventory_report(fixtures: list[dict[str, Any]]) -> dict[str, Any]:
  """Return a deterministic inventory with one stable identity per test."""
  files = []
  tests = []

  for fixture in sorted(fixtures, key=lambda value: value["path"]):
    path = fixture["path"]
    descriptions = fixture["tests"]
    files.append({
      "description": fixture["description"],
      "path": path,
      "schema_version": fixture["schema_version"],
      "tests": len(descriptions),
    })

    for index, description in enumerate(descriptions, 1):
      tests.append({
        "description": description,
        "fixture": path,
        "id": f"{path}::test[{index}]",
        "index": index,
      })

  return {
    "files": files,
    "report_version": REPORT_VERSION,
    "summary": {"files": len(files), "tests": len(tests)},
    "tests": tests,
    "type": "inventory",
  }


def validate_ratchets(
  classifications: list[dict[str, Any]],
  ratchets: dict[str, Any],
  passed: int = 0,
) -> None:
  expected = {"classified", "passed", "runnable"}

  if set(ratchets) != expected:
    raise CapabilityError("capability ratchets must define classified, passed, and runnable")

  for key, value in ratchets.items():
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
      raise CapabilityError(f"capability ratchet {key} must be a non-negative integer")

  current = {
    "classified": len(classifications),
    "passed": passed,
    "runnable": sum(value["status"] == "runnable" for value in classifications),
  }

  for key, minimum in ratchets.items():
    if current[key] < minimum:
      raise CapabilityError(
        f"capability {key} regressed from {minimum} to {current[key]}"
      )


def build_report(
  classifications: list[dict[str, Any]],
  ratchets: dict[str, Any] | None = None,
  execute: Any = None,
) -> dict[str, Any]:
  """Build an execution report without conflating deferral with execution."""
  tests = []
  summary = {
    "conformant": False,
    "deferred_unsupported": 0,
    "environment_skipped": 0,
    "executed": 0,
    "excluded_scope": 0,
    "failed": 0,
    "invalid_or_incompatible": 0,
    "passed": 0,
    "selected": len(classifications),
  }

  for classification in classifications:
    item = dict(classification)

    if item["status"] == "deferred_unsupported":
      summary["deferred_unsupported"] += 1
    elif item["status"] == "excluded_scope":
      summary["excluded_scope"] += 1
    elif execute is not None:
      status, detail = execute(item)
      item["status"] = status
      summary["executed"] += 1

      if status == "passed":
        summary["passed"] += 1
      elif status == "environment_skipped":
        summary["environment_skipped"] += 1
        summary["executed"] -= 1
      else:
        item["error"] = detail or "unified executor failed"
        summary["failed"] += 1
    else:
      item["status"] = "failed"
      item["error"] = "runnable test has no registered executor"
      summary["failed"] += 1

    tests.append(item)

  summary["conformant"] = (
    summary["executed"] > 0
    and summary["failed"] == 0
    and summary["deferred_unsupported"] == 0
    and summary["invalid_or_incompatible"] == 0
  )

  if ratchets is not None:
    try:
      validate_ratchets(
        classifications,
        ratchets,
        summary["passed"] + summary["environment_skipped"],
      )
    except CapabilityError as exc:
      failures = [
        f"{item['id']}: {item['error']}"
        for item in tests
        if item["status"] == "failed"
      ]

      if failures:
        raise CapabilityError(f"{exc}; {'; '.join(failures)}") from exc

      raise

  return {
    "ratchets": ratchets or {"classified": 0, "passed": 0, "runnable": 0},
    "report_version": REPORT_VERSION,
    "summary": summary,
    "tests": tests,
    "type": "execution",
  }


def aggregate_timing_reports(
  reports: list[dict[str, Any]],
) -> dict[str, Any] | None:
  """Combine shard timing observations without using them as test evidence."""
  timing_reports = [report.get("timings") for report in reports]

  if all(timings is None for timings in timing_reports):
    return None

  if any(not isinstance(timings, dict) for timings in timing_reports):
    raise CapabilityError("every shard report must include timing metadata")

  setup_ms = 0.0
  total_ms = 0.0
  environments: dict[str, float] = {}
  fixture_groups: list[dict[str, Any]] = []

  def duration(value: Any, label: str) -> float:
    if (
      not isinstance(value, (int, float))
      or isinstance(value, bool)
      or not math.isfinite(value)
      or value < 0
    ):
      raise CapabilityError(f"{label} must be a non-negative number")

    return float(value)

  for timings in timing_reports:
    setup_ms += duration(timings.get("setup_ms"), "shard setup_ms")
    total_ms += duration(timings.get("total_ms"), "shard total_ms")
    environment_rows = timings.get("environments")
    group_rows = timings.get("fixture_groups")

    if not isinstance(environment_rows, list):
      raise CapabilityError("shard timing environments must be an array")

    if not isinstance(group_rows, list):
      raise CapabilityError("shard timing fixture_groups must be an array")

    for row in environment_rows:
      if not isinstance(row, dict) or not isinstance(row.get("environment"), str):
        raise CapabilityError("shard timing environment row is malformed")

      environment = row["environment"]
      environments[environment] = environments.get(environment, 0.0) + duration(
        row.get("duration_ms"),
        f"shard {environment} environment duration_ms",
      )

    for row in group_rows:
      if (
        not isinstance(row, dict)
        or not isinstance(row.get("fixture"), str)
        or not isinstance(row.get("environment"), str)
        or type(row.get("tests")) is not int
        or row["tests"] <= 0
      ):
        raise CapabilityError("shard timing fixture-group row is malformed")

      fixture_groups.append({
        "duration_ms": duration(
          row.get("duration_ms"),
          f"shard {row['fixture']} fixture-group duration_ms",
        ),
        "environment": row["environment"],
        "fixture": row["fixture"],
        "tests": row["tests"],
      })

  return _timing_report(
    setup_ms,
    total_ms,
    environments,
    fixture_groups,
  )


def aggregate_shard_reports(
  classifications: list[dict[str, Any]],
  ratchets: dict[str, Any],
  reports: list[dict[str, Any]],
) -> dict[str, Any]:
  """Merge exact shard rows and enforce the unsharded global ratchets."""
  if not reports:
    raise CapabilityError("shard aggregation requires at least one report")

  first_shard = reports[0].get("shard")

  if not isinstance(first_shard, dict):
    raise CapabilityError("shard report is missing shard metadata")

  count = first_shard.get("count")

  if type(count) is not int or count <= 0:
    raise CapabilityError("shard report count must be a positive integer")

  if len(reports) != count:
    raise CapabilityError(
      f"shard aggregation expected {count} reports, got {len(reports)}"
    )

  expected = {classification["id"]: classification for classification in classifications}
  rows: dict[str, dict[str, Any]] = {}
  indices = set()

  for report in reports:
    if report.get("report_version") != REPORT_VERSION:
      raise CapabilityError("shard report version is incompatible")

    if report.get("type") != "execution":
      raise CapabilityError("shard report is not an execution report")

    shard = report.get("shard")

    if not isinstance(shard, dict) or shard.get("count") != count:
      raise CapabilityError("shard reports disagree on shard count")

    index = shard.get("index")

    if type(index) is not int or index < 0 or index >= count:
      raise CapabilityError("shard report index is invalid")

    if index in indices:
      raise CapabilityError(f"duplicate shard report index: {index}")

    indices.add(index)
    report_rows = report.get("tests")

    if not isinstance(report_rows, list):
      raise CapabilityError(f"shard {index} test rows must be an array")

    for row in report_rows:
      if not isinstance(row, dict) or not isinstance(row.get("id"), str):
        raise CapabilityError(f"shard {index} contains a malformed test row")

      identity = row["id"]
      classification = expected.get(identity)

      if classification is None:
        raise CapabilityError(f"shard {index} contains unknown test identity: {identity}")

      if identity in rows:
        raise CapabilityError(f"duplicate shard test identity: {identity}")

      if classification_shard(classification, count) != index:
        raise CapabilityError(f"test identity is assigned to the wrong shard: {identity}")

      for field in (
        "activity", "description", "fingerprint", "fixture", "id", "index",
        "requirements",
      ):
        if field in classification and row.get(field) != classification[field]:
          raise CapabilityError(
            f"shard row changed classification field {field}: {identity}"
          )

      expected_status = classification["status"]
      status = row.get("status")

      if expected_status != "runnable" and status != expected_status:
        raise CapabilityError(f"shard row changed deferred status: {identity}")

      if expected_status == "runnable" and status not in {
        "environment_skipped", "failed", "passed",
      }:
        raise CapabilityError(f"shard row has invalid execution status: {identity}")

      rows[identity] = row

  if indices != set(range(count)):
    missing_indices = sorted(set(range(count)) - indices)
    raise CapabilityError(f"missing shard report index: {missing_indices[0]}")

  missing = [identity for identity in expected if identity not in rows]

  if missing:
    raise CapabilityError(f"missing test identity from shard reports: {missing[0]}")

  def outcome(classification: dict[str, Any]) -> tuple[str, str | None]:
    row = rows[classification["id"]]
    error = row.get("error")
    return row["status"], error if isinstance(error, str) else None

  aggregate = build_report(classifications, ratchets, outcome)
  aggregate["aggregation"] = {"shards": count}
  timings = aggregate_timing_reports(reports)

  if timings is not None:
    aggregate["timings"] = timings

  return aggregate


def lua_batch_executor(
  lua: str,
  executable: Path,
  environment: dict[str, str] | None = None,
):
  """Return a fixture-batch executor backed by one Lua driver bridge process."""
  def failed_results(
    classifications: list[dict[str, Any]],
    detail: str,
  ) -> dict[str, tuple[str, str | None]]:
    return {
      classification["id"]: ("failed", detail)
      for classification in classifications
    }

  def execute(
    classifications: list[dict[str, Any]],
  ) -> dict[str, tuple[str, str | None]]:
    identities = [classification["id"] for classification in classifications]

    if not identities:
      return {}

    try:
      process = subprocess.run(
        [lua, str(executable), *identities],
        cwd=ROOT,
        env=environment or os.environ.copy(),
        text=True,
        capture_output=True,
      )
    except OSError as exc:
      return failed_results(
        classifications,
        f"could not start unified executor: {exc}",
      )

    detail = (process.stderr or process.stdout).strip()

    if process.returncode == 75:
      return {
        identity: (
          "environment_skipped",
          detail or "test commands are unavailable",
        )
        for identity in identities
      }

    if process.returncode != 0:
      return failed_results(
        classifications,
        detail or f"unified executor exited {process.returncode}",
      )

    try:
      report = json.loads(process.stdout)
      rows = report["results"]
    except (json.JSONDecodeError, KeyError, TypeError) as exc:
      def output_detail(value: str) -> str:
        normalized = value.strip()

        if not normalized:
          return "<empty>"

        limit = 1000
        if len(normalized) > limit:
          return normalized[:limit] + "..."

        return normalized

      return failed_results(
        classifications,
        "unified executor returned a malformed batch report: "
        f"{exc}; exit code {process.returncode}; "
        f"stdout: {output_detail(process.stdout)}; "
        f"stderr: {output_detail(process.stderr)}",
      )

    if not isinstance(rows, list):
      return failed_results(
        classifications,
        "unified executor returned a malformed batch result list",
      )

    results: dict[str, tuple[str, str | None]] = {}

    for row in rows:
      if not isinstance(row, dict):
        return failed_results(
          classifications,
          "unified executor returned a non-object batch result",
        )

      identity = row.get("id")
      status = row.get("status")
      error = row.get("error")

      if identity not in identities or identity in results:
        return failed_results(
          classifications,
          "unified executor returned an unknown or duplicate test identity",
        )

      if status not in {"environment_skipped", "failed", "passed"}:
        return failed_results(
          classifications,
          f"unified executor returned an unknown status for {identity}",
        )

      if error is not None and not isinstance(error, str):
        return failed_results(
          classifications,
          f"unified executor returned a non-string error for {identity}",
        )

      results[identity] = (status, error)

    if set(results) != set(identities):
      return failed_results(
        classifications,
        "unified executor omitted a selected test identity",
      )

    return results

  return execute


def lua_executor(lua: str, executable: Path, environment: dict[str, str] | None = None):
  """Return an exact per-test adapter over the fixture-batch Lua bridge."""
  execute_batch = lua_batch_executor(lua, executable, environment)

  def execute(classification: dict[str, Any]) -> tuple[str, str | None]:
    return execute_batch([classification])[classification["id"]]

  return execute


def execution_batches(
  classifications: list[dict[str, Any]],
  registry: dict[str, Any],
) -> list[list[dict[str, Any]]]:
  """Group runnable identities stably by fixture and deployment environment."""
  grouped: dict[tuple[str, Any, str | None], list[dict[str, Any]]] = {}

  for classification in classifications:
    if classification["status"] != "runnable":
      continue

    entry = registry.get(classification["id"], {})
    fixture = classification["fixture"]
    isolated_identity = (
      classification["id"] if fixture in PROCESS_ISOLATED_FIXTURES else None
    )
    key = (fixture, entry.get("environment"), isolated_identity)
    grouped.setdefault(key, []).append(classification)

  return list(grouped.values())


def load_executor_registry(path: Path = DEFAULT_EXECUTOR_REGISTRY) -> dict[str, Any]:
  try:
    registry = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load unified executor registry: {exc}") from exc

  if registry.get("schema_version") != 1 or not isinstance(registry.get("tests"), dict):
    raise CapabilityError("unified executor registry is malformed")

  return registry["tests"]


def apply_environment_overrides(registry: dict[str, Any]) -> dict[str, Any]:
  """Reuse one replica set for CSOT while retaining all other isolation."""
  effective = {
    identity: dict(entry)
    for identity, entry in registry.items()
  }

  for identity, entry in effective.items():
    if (
      identity.startswith(CSOT_FIXTURE_PREFIX)
      and entry.get("environment") == "isolated-replicaset"
    ):
      entry["environment"] = "live-replicaset"

  return effective


def platform_environment_skip(
  identity: str,
  environment: dict[str, str],
  platform: str | None = None,
) -> str | None:
  """Return the reason an otherwise runnable case cannot run on this host."""
  platform = platform or sys.platform

  if (
    environment.get("CI")
    and not environment.get("MONGODB_UNIFIED_RUN_TIMING_SENSITIVE_CSOT")
    and platform == "darwin"
    and identity in MACOS_CI_TIMING_SENSITIVE_CSOT
  ):
    return (
      "millisecond-scale CSOT failpoint timing is unreliable on macOS CI; "
      "the case remains authoritative on portable Linux"
    )

  if (
    environment.get("CI")
    and not environment.get("MONGODB_UNIFIED_RUN_TIMING_SENSITIVE_CSOT")
    and platform == "linux"
    and identity in LINUX_CI_FOCUSED_CSOT
  ):
    return (
      "the 90 ms CSOT short-circuit case runs as focused Linux CI evidence "
      "outside the loaded unified shard"
    )

  return None


def _free_port() -> int:
  with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
    listener.bind(("127.0.0.1", 0))
    return int(listener.getsockname()[1])


def _mongod_version(executable: str) -> str:
  try:
    process = subprocess.run(
      [executable, "--version"],
      check=True,
      capture_output=True,
      text=True,
    )
  except (OSError, subprocess.CalledProcessError) as exc:
    raise CapabilityError(f"could not inspect mongod: {exc}") from exc

  match = re.search(r"db version v(\d+\.\d+\.\d+)", process.stdout)

  if not match:
    raise CapabilityError("mongod --version did not report a semantic version")

  return match.group(1)


@contextmanager
def standalone_environment(
  classifications: list[dict[str, Any]],
  registry: dict[str, Any],
  authenticated: bool = False,
):
  environment_name = (
    AUTHENTICATED_STANDALONE_ENVIRONMENT if authenticated else "live-standalone"
  )
  uri_name = AUTHENTICATED_STANDALONE_URI if authenticated else "MONGODB_UNIFIED_URI"
  version_name = (
    AUTHENTICATED_STANDALONE_VERSION
    if authenticated else "MONGODB_UNIFIED_SERVER_VERSION"
  )
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment") == environment_name
    for value in classifications
  )
  environment = os.environ.copy()

  if not needs_server:
    yield environment
    return

  configured_uri = environment.get(uri_name)

  if configured_uri:
    if not environment.get(version_name):
      raise CapabilityError(
        f"{version_name} is required with {uri_name}"
      )

    if authenticated and "@" not in urlsplit(configured_uri).netloc:
      raise CapabilityError(f"{uri_name} must include authentication credentials")

    yield environment
    return

  executable = environment.get("MONGOD") or shutil.which("mongod")
  shell = environment.get("MONGOSH") or shutil.which("mongosh")

  if not executable or (authenticated and not shell):
    raise CapabilityError(
      "runnable live unified cases require mongod"
      + (" and mongosh" if authenticated else "")
    )

  version = _mongod_version(executable)
  port = _free_port()
  mongod_command = [
    executable,
    "--bind_ip", "127.0.0.1",
    "--dbpath", "",
    "--logpath", "",
    "--nounixsocket",
    "--port", str(port),
    "--quiet",
    "--setParameter", "enableTestCommands=1",
  ]
  accepts_api_version_2 = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("acceptApiVersion2") is True
    for value in classifications
  )

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-unified-") as directory:
    root = Path(directory)
    (root / "db").mkdir()
    mongod_command[4] = str(root / "db")
    mongod_command[6] = str(root / "mongod.log")

    if accepts_api_version_2:
      mongod_command.extend(["--setParameter", "acceptApiVersion2=1"])

    if authenticated:
      mongod_command.append("--auth")

    process = subprocess.Popen(
      mongod_command,
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )

    try:
      deadline = time.monotonic() + 15

      while time.monotonic() < deadline:
        if process.poll() is not None:
          log = (root / "mongod.log")
          detail = log.read_text(encoding="utf-8")[-2000:] if log.exists() else ""
          raise CapabilityError(
            f"ephemeral mongod exited {process.returncode}: {detail.strip()}"
          )

        try:
          with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            break
        except OSError:
          time.sleep(0.05)
      else:
        raise CapabilityError("ephemeral mongod did not become ready within 15 seconds")

      uri = f"mongodb://127.0.0.1:{port}"

      if authenticated:
        username = "lua_mongodb_unified"
        password = "lua_mongodb_unified_password"
        create_user = subprocess.run(
          [
            shell,
            f"{uri}/admin",
            "--quiet",
            "--eval",
            (
              'db.createUser({user:"' + username + '",pwd:"' + password
              + '",roles:[{role:"root",db:"admin"}]})'
            ),
          ],
          capture_output=True,
          text=True,
        )

        if create_user.returncode != 0:
          raise CapabilityError(
            "could not create ephemeral authenticated unified user: "
            + (create_user.stderr or create_user.stdout).strip()
          )

        uri = f"mongodb://{username}:{password}@127.0.0.1:{port}/admin"

      environment[uri_name] = uri
      environment[version_name] = version
      environment["MONGODB_UNIFIED_TEST_COMMANDS"] = "1"
      yield environment
    finally:
      if process.poll() is None:
        process.terminate()

        try:
          process.wait(timeout=10)
        except subprocess.TimeoutExpired:
          process.kill()
          process.wait(timeout=5)


@contextmanager
def replica_set_environment(
  classifications: list[dict[str, Any]],
  registry: dict[str, Any],
  base_environment: dict[str, str],
  authenticated: bool = False,
):
  environment_name = (
    AUTHENTICATED_REPLICA_SET_ENVIRONMENT if authenticated else "live-replicaset"
  )
  uri_name = (
    AUTHENTICATED_REPLICA_SET_URI
    if authenticated else "MONGODB_UNIFIED_REPLICA_SET_URI"
  )
  version_name = (
    AUTHENTICATED_REPLICA_SET_VERSION
    if authenticated else "MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION"
  )
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment") == environment_name
    for value in classifications
  )
  environment = base_environment.copy()

  if not needs_server:
    yield environment
    return

  member_count = max(
    (
      registry.get(value["id"], {}).get("replicaSetMembers", 1)
      for value in classifications
      if value["status"] == "runnable"
      and registry.get(value["id"], {}).get("environment") == environment_name
    ),
    default=1,
  )

  if type(member_count) is not int or member_count < 1 or member_count > 3:
    raise CapabilityError("replicaSetMembers must be an integer from 1 through 3")

  configured_uri = environment.get(uri_name)

  if configured_uri:
    if not environment.get(version_name):
      raise CapabilityError(
        f"{version_name} is required with {uri_name}"
      )

    if authenticated and "@" not in urlsplit(configured_uri).netloc:
      raise CapabilityError(f"{uri_name} must include authentication credentials")

    yield environment
    return

  executable = environment.get("MONGOD") or shutil.which("mongod")
  shell = environment.get("MONGOSH") or shutil.which("mongosh")

  if not executable or not shell:
    raise CapabilityError(
      "runnable replica-set cases require mongod and mongosh"
    )

  version = _mongod_version(executable)
  ports: list[int] = []

  while len(ports) < member_count:
    port = _free_port()

    if port not in ports:
      ports.append(port)

  set_name = "lua-mongodb-unified"
  direct_uri = f"mongodb://127.0.0.1:{ports[0]}"

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-unified-rs-") as directory:
    root = Path(directory)
    processes: list[subprocess.Popen[bytes]] = []
    key_file = root / "replica-set-key"

    if authenticated:
      key_file.write_text(
        "bHVhLW1vbmdvZGItZHJpdmVyLXVuaWZpZWQtdGVzdC1rZXk=\n",
        encoding="utf-8",
      )
      key_file.chmod(0o600)

    for index, port in enumerate(ports):
      database_path = root / f"db-{index}"
      database_path.mkdir()
      command = [
          executable,
          "--bind_ip", "127.0.0.1",
          "--dbpath", str(database_path),
          "--logpath", str(root / f"mongod-{index}.log"),
          "--nounixsocket",
          "--port", str(port),
          "--quiet",
          "--replSet", set_name,
          "--setParameter", "enableTestCommands=1",
      ]

      if authenticated:
        command.extend(["--auth", "--keyFile", str(key_file)])

      processes.append(subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
      ))

    try:
      deadline = time.monotonic() + 60

      for index, (port, process) in enumerate(zip(ports, processes)):
        while time.monotonic() < deadline:
          if process.poll() is not None:
            log = root / f"mongod-{index}.log"
            detail = log.read_text(encoding="utf-8")[-2000:] if log.exists() else ""
            raise CapabilityError(
              f"ephemeral replica-set member exited {process.returncode}: "
              f"{detail.strip()}"
            )

          try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
              break
          except OSError:
            time.sleep(0.05)
        else:
          raise CapabilityError(
            "ephemeral replica-set members did not start within 60 seconds"
          )

      members = ",".join(
        f'{{_id:{index},host:"127.0.0.1:{port}"}}'
        for index, port in enumerate(ports)
      )
      configuration = f'{{_id:"{set_name}",members:[{members}]'

      if member_count > 1:
        configuration += ",settings:{electionTimeoutMillis:1000}"

      configuration += "}"

      initiate = subprocess.run(
        [
          shell,
          direct_uri,
          "--quiet",
          "--eval",
          f"rs.initiate({configuration})",
        ],
        capture_output=True,
        text=True,
      )

      if initiate.returncode != 0:
        raise CapabilityError(
          "could not initiate ephemeral replica set: "
          + (initiate.stderr or initiate.stdout).strip()
        )

      while time.monotonic() < deadline:
        primary = subprocess.run(
          [
            shell,
            direct_uri,
            "--quiet",
            "--eval",
            "quit(db.hello().isWritablePrimary ? 0 : 1)",
          ],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
        )

        if primary.returncode == 0:
          break

        time.sleep(0.1)
      else:
        raise CapabilityError("ephemeral replica set did not elect a primary")

      seed_list = ",".join(f"127.0.0.1:{port}" for port in ports)
      uri = (
        f"mongodb://{seed_list}/?replicaSet={set_name}"
        "&serverSelectionTimeoutMS=5000&heartbeatFrequencyMS=500"
      )

      if authenticated:
        username = "lua_mongodb_unified"
        password = "lua_mongodb_unified_password"
        create_user = subprocess.run(
          [
            shell,
            f"{direct_uri}/admin",
            "--quiet",
            "--eval",
            (
              'db.createUser({user:"' + username + '",pwd:"' + password
              + '",roles:[{role:"root",db:"admin"}]})'
            ),
          ],
          capture_output=True,
          text=True,
        )

        if create_user.returncode != 0:
          raise CapabilityError(
            "could not create ephemeral authenticated replica-set user: "
            + (create_user.stderr or create_user.stdout).strip()
          )

        uri = (
          f"mongodb://{username}:{password}@{seed_list}/admin?replicaSet={set_name}"
          "&serverSelectionTimeoutMS=5000&heartbeatFrequencyMS=500"
        )

      environment[uri_name] = uri
      environment[version_name] = version
      environment["MONGODB_UNIFIED_TEST_COMMANDS"] = "1"
      yield environment
    finally:
      for process in processes:
        if process.poll() is None:
          process.terminate()

      for process in processes:
        if process.poll() is None:
          try:
            process.wait(timeout=10)
          except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


@contextmanager
def sharded_environment(
  classifications: list[dict[str, Any]],
  registry: dict[str, Any],
  base_environment: dict[str, str],
):
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment")
      in {"live-sharded", LOAD_BALANCED_ENVIRONMENT}
    for value in classifications
  )
  environment = base_environment.copy()
  needs_load_balanced = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment")
      == LOAD_BALANCED_ENVIRONMENT
    for value in classifications
  )

  if not needs_server:
    yield environment
    return

  mongos_count = max(
    (
      registry.get(value["id"], {}).get("mongoses", 1)
      for value in classifications
      if value["status"] == "runnable"
      and registry.get(value["id"], {}).get("environment") == "live-sharded"
    ),
    default=1,
  )

  if type(mongos_count) is not int or mongos_count < 1 or mongos_count > 2:
    raise CapabilityError("mongoses must be an integer from 1 through 2")

  configured_uri = environment.get("MONGODB_UNIFIED_SHARDED_URI")

  if configured_uri:
    version = environment.get("MONGODB_UNIFIED_SHARDED_SERVER_VERSION")
    encoded_facts = environment.get("MONGODB_UNIFIED_SHARDED_FACTS")

    if not version:
      raise CapabilityError(
        "MONGODB_UNIFIED_SHARDED_SERVER_VERSION is required with "
        "MONGODB_UNIFIED_SHARDED_URI"
      )

    if not encoded_facts:
      raise CapabilityError(
        "MONGODB_UNIFIED_SHARDED_FACTS is required with "
        "MONGODB_UNIFIED_SHARDED_URI"
      )

    try:
      facts = sharded_cluster.validate_facts(json.loads(encoded_facts))
    except (json.JSONDecodeError, sharded_cluster.ShardedEnvironmentError) as exc:
      raise CapabilityError(f"invalid sharded environment facts: {exc}") from exc

    if facts["server_version"] != version:
      raise CapabilityError(
        "sharded environment facts do not match the configured server version"
      )

    if len(facts["mongoses"]) < mongos_count:
      raise CapabilityError(
        f"sharded environment requires {mongos_count} mongoses"
      )

    if needs_load_balanced and not environment.get(LOAD_BALANCED_URI):
      raise CapabilityError(
        f"{LOAD_BALANCED_URI} is required for external load-balanced cases"
      )

    if needs_load_balanced and not environment.get(LOAD_BALANCED_VERSION):
      raise CapabilityError(
        f"{LOAD_BALANCED_VERSION} is required with {LOAD_BALANCED_URI}"
      )

    parsed_uri = urlsplit(configured_uri)
    credentials = (
      parsed_uri.netloc.rsplit("@", 1)[0] + "@"
      if "@" in parsed_uri.netloc else ""
    )
    environment["MONGODB_UNIFIED_SHARDED_MULTIPLE_MONGOS_URI"] = urlunsplit((
      parsed_uri.scheme,
      credentials + ",".join(facts["mongoses"][:mongos_count]),
      parsed_uri.path,
      parsed_uri.query,
      parsed_uri.fragment,
    ))

    yield environment
    return

  try:
    with sharded_cluster.cluster(
      mongod=environment.get("MONGOD"),
      mongos=environment.get("MONGOS"),
      mongosh=environment.get("MONGOSH"),
      mongos_count=mongos_count,
      load_balanced=needs_load_balanced,
    ) as deployment:
      facts = deployment["facts"]
      environment["MONGODB_UNIFIED_SHARDED_URI"] = deployment["uri"]
      environment["MONGODB_UNIFIED_SHARDED_MULTIPLE_MONGOS_URI"] = deployment[
        "multiple_mongos_uri"
      ]
      environment["MONGODB_UNIFIED_SHARDED_SERVER_VERSION"] = facts[
        "server_version"
      ]
      environment["MONGODB_UNIFIED_SHARDED_FACTS"] = json.dumps(
        facts,
        sort_keys=True,
      )
      if needs_load_balanced:
        environment[LOAD_BALANCED_URI] = deployment["load_balanced_uri"]
        environment[LOAD_BALANCED_VERSION] = facts["server_version"]
      environment["MONGODB_UNIFIED_TEST_COMMANDS"] = (
        "1" if deployment["test_commands"] else "0"
      )
      yield environment
  except sharded_cluster.ShardedEnvironmentError as exc:
    raise CapabilityError(str(exc)) from exc


@contextmanager
def load_balanced_environment(
  classifications: list[dict[str, Any]],
  registry: dict[str, Any],
  base_environment: dict[str, str],
):
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment")
      == LOAD_BALANCED_ENVIRONMENT
    for value in classifications
  )
  environment = base_environment.copy()

  if not needs_server:
    yield environment
    return

  configured_uri = environment.get(LOAD_BALANCED_URI)

  if configured_uri:
    if not environment.get(LOAD_BALANCED_VERSION):
      raise CapabilityError(
        f"{LOAD_BALANCED_VERSION} is required with {LOAD_BALANCED_URI}"
      )

    yield environment
    return

  raise CapabilityError(
    "load-balanced cases require a mongos loadBalancerPort endpoint"
  )


def write_report(report: dict[str, Any], destination: str | None) -> None:
  encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"

  if destination == "-":
    print(encoded, end="")
  elif destination:
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(encoded, encoding="utf-8")


def finish_report(report: dict[str, Any], destination: str | None) -> int:
  write_report(report, destination)
  summary = report["summary"]
  print(
    f"unified execution: {summary['executed']} executed, "
    f"{summary['passed']} passed, {summary['failed']} failed, "
    f"{summary['environment_skipped']} environment-skipped, "
    f"{summary['deferred_unsupported']} deferred-unsupported; "
    f"conformant={str(summary['conformant']).lower()}",
    file=sys.stderr if destination == "-" else sys.stdout,
  )
  return 1 if summary["failed"] else 0


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
  parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
  parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
  parser.add_argument("--progress", type=Path, default=DEFAULT_PROGRESS)
  parser.add_argument("--executor", type=Path, default=DEFAULT_EXECUTOR)
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  parser.add_argument("--include", action="append")
  parser.add_argument("--shard-count", type=int)
  parser.add_argument("--shard-index", type=int)
  parser.add_argument("--aggregate", nargs="+", type=Path)
  parser.add_argument("--report", metavar="PATH")
  arguments = parser.parse_args(argv)
  timings = ExecutionTimings()

  try:
    discovered = discover_tests(arguments.source)

    if not discovered:
      raise CapabilityError("unified fixture discovery found no files")

    manifest = load_manifest(arguments.manifest)
    activity_states = load_activity_states(arguments.plan, arguments.progress)
    classified = classify_tests(discovered, manifest["tests"], activity_states)
    validate_ratchets(
      classified,
      manifest["ratchets"],
      manifest["ratchets"].get("passed", 0),
    )
    selected = select_classifications(classified, arguments.include)

    if arguments.include and not selected:
      raise CapabilityError("unified --include selector matched no tests")

    if arguments.aggregate:
      if arguments.include:
        raise CapabilityError("shard aggregation cannot use --include")

      if arguments.shard_count is not None or arguments.shard_index is not None:
        raise CapabilityError("shard aggregation cannot select a shard")

      reports = []

      for path in arguments.aggregate:
        try:
          reports.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as exc:
          raise CapabilityError(f"could not load shard report {path}: {exc}") from exc

      report = aggregate_shard_reports(
        selected,
        manifest["ratchets"],
        reports,
      )
      return finish_report(report, arguments.report)

    has_shard_count = arguments.shard_count is not None
    has_shard_index = arguments.shard_index is not None

    if has_shard_count != has_shard_index:
      raise CapabilityError("--shard-count and --shard-index must be used together")

    if has_shard_count:
      selected = select_shard(
        selected,
        arguments.shard_count,
        arguments.shard_index,
      )

      if not selected:
        raise CapabilityError("unified shard selected no tests")

    registry = apply_environment_overrides(load_executor_registry())

    batches = execution_batches(selected, registry)
    batch_progress = ExecutionProgress(len(batches))

    def execute_batch(
      batch: list[dict[str, Any]],
      environment: dict[str, str],
    ) -> dict[str, tuple[str, str | None]]:
      entry = registry.get(batch[0]["id"], {})
      environment_name = entry.get("environment") or "unregistered"
      progress_started = batch_progress.start(batch, environment_name)

      with timings.observe_fixture_group(batch, environment_name):
        runnable = []
        results: dict[str, tuple[str, str | None]] = {}

        for classification in batch:
          skip_reason = platform_environment_skip(
            classification["id"],
            environment,
          )

          if skip_reason:
            results[classification["id"]] = (
              "environment_skipped",
              skip_reason,
            )
          else:
            runnable.append(classification)

        if runnable:
          results.update(lua_batch_executor(
            arguments.lua,
            arguments.executor,
            environment,
          )(runnable))

        batch_progress.finish(
          batch,
          environment_name,
          results,
          progress_started,
        )
        return results

    timings.finish_setup()
    execution_results: dict[str, tuple[str, str | None]] = {}
    authenticated_batches = [
      batch
      for batch in batches
      if registry.get(batch[0]["id"], {}).get("environment")
        == AUTHENTICATED_STANDALONE_ENVIRONMENT
    ]

    if authenticated_batches:
      authenticated_classifications = [
        classification
        for batch in authenticated_batches
        for classification in batch
      ]

      with ExitStack() as authenticated_resources:
        with timings.observe_environment(AUTHENTICATED_STANDALONE_ENVIRONMENT):
          authenticated_environment = authenticated_resources.enter_context(
            standalone_environment(
              authenticated_classifications,
              registry,
              authenticated=True,
            )
          )

        for batch in authenticated_batches:
          execution_results.update(execute_batch(batch, authenticated_environment))

    authenticated_replica_set_batches = [
      batch
      for batch in batches
      if registry.get(batch[0]["id"], {}).get("environment")
        == AUTHENTICATED_REPLICA_SET_ENVIRONMENT
    ]

    if authenticated_replica_set_batches:
      authenticated_replica_set_classifications = [
        classification
        for batch in authenticated_replica_set_batches
        for classification in batch
      ]

      with ExitStack() as authenticated_resources:
        with timings.observe_environment(AUTHENTICATED_REPLICA_SET_ENVIRONMENT):
          authenticated_environment = authenticated_resources.enter_context(
            replica_set_environment(
              authenticated_replica_set_classifications,
              registry,
              os.environ.copy(),
              authenticated=True,
            )
          )

        for batch in authenticated_replica_set_batches:
          execution_results.update(execute_batch(batch, authenticated_environment))

    for batch in batches:
      entry = registry.get(batch[0]["id"], {})

      if entry.get("environment") != "isolated-replicaset":
        continue

      isolated_registry = {
        classification["id"]: {
          "environment": "live-replicaset",
          "replicaSetMembers": registry.get(
            classification["id"], {},
          ).get("replicaSetMembers", 1),
        }
        for classification in batch
      }
      member_count = max(
        entry["replicaSetMembers"]
        for entry in isolated_registry.values()
      )

      with ExitStack() as environments:
        isolated_standalone = environments.enter_context(
          standalone_environment(batch, isolated_registry)
        )

        if member_count > 1:
          isolated_standalone.pop("MONGODB_UNIFIED_REPLICA_SET_URI", None)
          isolated_standalone.pop(
            "MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION",
            None,
          )

        with timings.observe_environment("isolated-replicaset"):
          isolated_environment = environments.enter_context(
            replica_set_environment(
              batch,
              isolated_registry,
              isolated_standalone,
            )
          )

        execution_results.update(execute_batch(batch, isolated_environment))

    needed_environments = {
      registry.get(batch[0]["id"], {}).get("environment")
      for batch in batches
      if registry.get(batch[0]["id"], {}).get("environment") not in {
        "isolated-replicaset",
        AUTHENTICATED_REPLICA_SET_ENVIRONMENT,
        AUTHENTICATED_STANDALONE_ENVIRONMENT,
      }
    }

    with ExitStack() as environments:
      standalone_manager = standalone_environment(selected, registry)

      if "live-standalone" in needed_environments:
        with timings.observe_environment("live-standalone"):
          standalone = environments.enter_context(standalone_manager)
      else:
        standalone = environments.enter_context(standalone_manager)

      replica_set_manager = replica_set_environment(
        selected,
        registry,
        standalone,
      )

      if "live-replicaset" in needed_environments:
        with timings.observe_environment("live-replicaset"):
          environment = environments.enter_context(replica_set_manager)
      else:
        environment = environments.enter_context(replica_set_manager)

      sharded_manager = sharded_environment(
        selected,
        registry,
        environment,
      )

      if "live-sharded" in needed_environments:
        with timings.observe_environment("live-sharded"):
          environment = environments.enter_context(sharded_manager)
      else:
        environment = environments.enter_context(sharded_manager)

      load_balanced_manager = load_balanced_environment(
        selected,
        registry,
        environment,
      )

      if LOAD_BALANCED_ENVIRONMENT in needed_environments:
        with timings.observe_environment(LOAD_BALANCED_ENVIRONMENT):
          environment = environments.enter_context(load_balanced_manager)
      else:
        environment = environments.enter_context(load_balanced_manager)

      for batch in batches:
        entry = registry.get(batch[0]["id"], {})

        if entry.get("environment") not in {
          "isolated-replicaset",
          AUTHENTICATED_REPLICA_SET_ENVIRONMENT,
          AUTHENTICATED_STANDALONE_ENVIRONMENT,
        }:
          execution_results.update(execute_batch(batch, environment))

      report = build_report(
        selected,
        manifest["ratchets"]
          if not arguments.include and not has_shard_count else None,
        lambda classification: execution_results.get(
          classification["id"],
          ("failed", "unified batch omitted a runnable test identity"),
        )
      )

    if has_shard_count:
      report["shard"] = {
        "count": arguments.shard_count,
        "index": arguments.shard_index,
      }

    timings.attach(report)
  except CapabilityError as exc:
    print(f"unified capabilities: {exc}", file=sys.stderr)
    return 2

  return finish_report(report, arguments.report)


if __name__ == "__main__":
  raise SystemExit(main())
