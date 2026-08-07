#!/usr/bin/env python3
"""Discover and report pinned MongoDB unified test fixture capabilities."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fnmatch
import hashlib
import json
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


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "planning" / "specifications" / "source"
DEFAULT_MANIFEST = ROOT / "spec" / "unified" / "capabilities.json"
DEFAULT_PLAN = ROOT / "planning" / "plan.json"
DEFAULT_PROGRESS = ROOT / "planning" / "progress.json"
DEFAULT_EXECUTOR = ROOT / "spec" / "unified" / "execute.lua"
DEFAULT_EXECUTOR_REGISTRY = ROOT / "spec" / "unified" / "executors.json"
VALID_STATUSES = {"deferred_unsupported", "excluded_scope", "runnable"}
REPORT_VERSION = 2
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
  "createCommandCursor", "createDataKey", "createFindCursor", "createIndex", "decrypt",
  "delete", "deleteKey", "deleteMany", "deleteOne", "distinct", "download",
  "downloadByName", "drop", "dropCollection", "dropIndex", "dropIndexes", "encrypt", "endSession",
  "estimatedDocumentCount", "find", "findOne", "findOneAndDelete",
  "findOneAndReplace", "findOneAndUpdate", "getKey", "getKeyByAltName",
  "getKeys", "insertMany", "insertOne", "iterateOnce",
  "iterateUntilDocumentOrError", "listCollectionNames",
  "listCollectionObjects", "listCollections", "listDatabaseNames",
  "listDatabaseObjects", "listDatabases", "listIndexNames", "listIndexes",
  "mapReduce", "modifyCollection", "removeKeyAltName", "rename",
  "replaceOne", "rewrapManyDataKey", "runCommand", "runCursorCommand",
  "startTransaction", "updateMany", "updateOne", "upload", "withTransaction",
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
  "serverHeartbeatStartedEvent", "serverHeartbeatSucceededEvent",
  "topologyClosedEvent", "topologyDescriptionChangedEvent", "topologyOpeningEvent",
}
KNOWN_TOPOLOGIES = {
  "load-balanced", "replicaset", "sharded", "sharded-replicaset", "single",
}


class CapabilityError(ValueError):
  """Raised when fixture discovery and the capability manifest diverge."""


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

    if not is_unified_directory and not is_csot_directory and not is_release_directory:
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
      status != "runnable"
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
    validate_ratchets(
      classifications,
      ratchets,
      summary["passed"] + summary["environment_skipped"],
    )

  return {
    "ratchets": ratchets or {"classified": 0, "passed": 0, "runnable": 0},
    "report_version": REPORT_VERSION,
    "summary": summary,
    "tests": tests,
    "type": "execution",
  }


def lua_executor(lua: str, executable: Path, environment: dict[str, str] | None = None):
  """Return an exact per-test executor backed by the Lua driver bridge."""
  def execute(classification: dict[str, Any]) -> tuple[str, str | None]:
    try:
      process = subprocess.run(
        [lua, str(executable), classification["id"]],
        cwd=ROOT,
        env=environment or os.environ.copy(),
        text=True,
        capture_output=True,
      )
    except OSError as exc:
      return "failed", f"could not start unified executor: {exc}"

    if process.returncode == 0:
      return "passed", None

    detail = (process.stderr or process.stdout).strip()
    if process.returncode == 75:
      return "environment_skipped", detail or "test commands are unavailable"

    return "failed", detail or f"unified executor exited {process.returncode}"

  return execute


def load_executor_registry(path: Path = DEFAULT_EXECUTOR_REGISTRY) -> dict[str, Any]:
  try:
    registry = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CapabilityError(f"could not load unified executor registry: {exc}") from exc

  if registry.get("schema_version") != 1 or not isinstance(registry.get("tests"), dict):
    raise CapabilityError("unified executor registry is malformed")

  return registry["tests"]


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
):
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment") == "live-standalone"
    for value in classifications
  )
  environment = os.environ.copy()

  if not needs_server:
    yield environment
    return

  configured_uri = environment.get("MONGODB_UNIFIED_URI")

  if configured_uri:
    if not environment.get("MONGODB_UNIFIED_SERVER_VERSION"):
      raise CapabilityError(
        "MONGODB_UNIFIED_SERVER_VERSION is required with MONGODB_UNIFIED_URI"
      )

    yield environment
    return

  executable = environment.get("MONGOD") or shutil.which("mongod")

  if not executable:
    raise CapabilityError(
      "runnable live unified cases require mongod; set MONGOD or MONGODB_UNIFIED_URI"
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

      environment["MONGODB_UNIFIED_URI"] = f"mongodb://127.0.0.1:{port}"
      environment["MONGODB_UNIFIED_SERVER_VERSION"] = version
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
):
  needs_server = any(
    value["status"] == "runnable"
    and registry.get(value["id"], {}).get("environment") == "live-replicaset"
    for value in classifications
  )
  environment = base_environment.copy()

  if not needs_server:
    yield environment
    return

  configured_uri = environment.get("MONGODB_UNIFIED_REPLICA_SET_URI")

  if configured_uri:
    if not environment.get("MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION"):
      raise CapabilityError(
        "MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION is required with "
        "MONGODB_UNIFIED_REPLICA_SET_URI"
      )

    yield environment
    return

  executable = environment.get("MONGOD") or shutil.which("mongod")
  shell = environment.get("MONGOSH") or shutil.which("mongosh")

  if not executable or not shell:
    raise CapabilityError(
      "runnable replica-set cases require mongod and mongosh"
    )

  version = _mongod_version(executable)
  port = _free_port()
  set_name = "lua-mongodb-unified"
  direct_uri = f"mongodb://127.0.0.1:{port}"

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-unified-rs-") as directory:
    root = Path(directory)
    (root / "db").mkdir()
    process = subprocess.Popen(
      [
        executable,
        "--bind_ip", "127.0.0.1",
        "--dbpath", str(root / "db"),
        "--logpath", str(root / "mongod.log"),
        "--nounixsocket",
        "--port", str(port),
        "--quiet",
        "--replSet", set_name,
        "--setParameter", "enableTestCommands=1",
      ],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )

    try:
      deadline = time.monotonic() + 20

      while time.monotonic() < deadline:
        if process.poll() is not None:
          log = root / "mongod.log"
          detail = log.read_text(encoding="utf-8")[-2000:] if log.exists() else ""
          raise CapabilityError(
            f"ephemeral replica set exited {process.returncode}: {detail.strip()}"
          )

        try:
          with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            break
        except OSError:
          time.sleep(0.05)
      else:
        raise CapabilityError("ephemeral replica set did not start within 20 seconds")

      initiate = subprocess.run(
        [
          shell,
          direct_uri,
          "--quiet",
          "--eval",
          (
            f'rs.initiate({{_id:"{set_name}",members:['
            f'{{_id:0,host:"127.0.0.1:{port}"}}]}})'
          ),
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

      environment["MONGODB_UNIFIED_REPLICA_SET_URI"] = (
        f"{direct_uri}/?replicaSet={set_name}"
        "&serverSelectionTimeoutMS=5000&heartbeatFrequencyMS=500"
      )
      environment["MONGODB_UNIFIED_REPLICA_SET_SERVER_VERSION"] = version
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


def write_report(report: dict[str, Any], destination: str | None) -> None:
  encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"

  if destination == "-":
    print(encoded, end="")
  elif destination:
    Path(destination).write_text(encoded, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
  parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
  parser.add_argument("--plan", type=Path, default=DEFAULT_PLAN)
  parser.add_argument("--progress", type=Path, default=DEFAULT_PROGRESS)
  parser.add_argument("--executor", type=Path, default=DEFAULT_EXECUTOR)
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  parser.add_argument("--include", action="append")
  parser.add_argument("--report", metavar="PATH")
  arguments = parser.parse_args(argv)

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
    registry = load_executor_registry()

    def execute_selected(classification: dict[str, Any], environment: dict[str, str]):
      entry = registry.get(classification["id"], {})

      if entry.get("environment") != "isolated-replicaset":
        return lua_executor(arguments.lua, arguments.executor, environment)(classification)

      isolated_registry = {
        classification["id"]: {"environment": "live-replicaset"},
      }

      with standalone_environment([classification], isolated_registry) as isolated_standalone:
        with replica_set_environment(
          [classification],
          isolated_registry,
          isolated_standalone,
        ) as isolated_environment:
          return lua_executor(
            arguments.lua,
            arguments.executor,
            isolated_environment,
          )(classification)

    isolated_results = {
      classification["id"]: execute_selected(classification, os.environ.copy())
      for classification in selected
      if registry.get(classification["id"], {}).get("environment")
        == "isolated-replicaset"
    }

    with standalone_environment(selected, registry) as standalone:
      with replica_set_environment(selected, registry, standalone) as environment:
        report = build_report(
          selected,
          manifest["ratchets"] if not arguments.include else None,
          lambda classification: isolated_results.get(classification["id"])
            or execute_selected(classification, environment),
        )
    write_report(report, arguments.report)
  except CapabilityError as exc:
    print(f"unified capabilities: {exc}", file=sys.stderr)
    return 2

  summary = report["summary"]
  print(
    f"unified execution: {summary['executed']} executed, "
    f"{summary['passed']} passed, {summary['failed']} failed, "
    f"{summary['environment_skipped']} environment-skipped, "
    f"{summary['deferred_unsupported']} deferred-unsupported; "
    f"conformant={str(summary['conformant']).lower()}",
    file=sys.stderr if arguments.report == "-" else sys.stdout,
  )
  return 1 if summary["failed"] else 0


if __name__ == "__main__":
  raise SystemExit(main())
