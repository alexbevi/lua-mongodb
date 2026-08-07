#!/usr/bin/env python3
"""Regenerate per-test unified capability classifications."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.unified import run  # noqa: E402


PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
OUTPUT = ROOT / "spec" / "unified" / "capabilities.json"
EXECUTORS = ROOT / "spec" / "unified" / "executors.json"
EXECUTOR_TESTS = json.loads(EXECUTORS.read_text(encoding="utf-8"))["tests"]
RATCHETS = {
  "classified": 1900,
  "passed": len(EXECUTOR_TESTS),
  "runnable": len(EXECUTOR_TESTS),
}

OWNER_REASONS = {
  "ADV-001": "change streams are a post-v1 capability",
  "ADV-002": "GridFS is a post-v1 capability",
  "ADV-005": "sharded execution is a post-v1 capability",
  "ADV-006": "load-balanced execution is a post-v1 capability",
  "ADV-007": "client bulkWrite is a post-v1 capability",
  "ADV-008": "the test requires a post-v1 authentication mechanism",
  "ADV-009": "logging, telemetry, and backpressure are post-v1 capabilities",
  "ADV-010": "client-side field-level and queryable encryption require a separate design",
  "ADV-011": "legacy commands, database aggregation, tailable cursors, snapshot sessions, and pre-v1 server behavior are post-v1 capabilities",
  "REL-002": "BSON vector behavior awaits the dedicated release conformance slice",
  "REL-003": "the case awaits the v1 configuration conformance slice",
  "REL-004": "the case awaits the v1 CRUD and administration conformance slice",
  "REL-005": "the case awaits the v1 command and cursor conformance slice",
  "REL-006": "the case awaits release retry and handshake hardening",
  "REL-010": "the case awaits the remaining v1 CRUD and administration conformance slices",
  "RETRY-001": "retryable-read orchestration is not implemented",
  "RETRY-002": "retryable-write orchestration is not implemented",
  "SDAM-002": "public monitoring, replica-set discovery, and SDAM event execution are not implemented",
  "SES-001": "session entities and causal command decoration are not implemented",
  "TXN-001": "explicit transaction execution is not implemented",
  "TXN-002": "convenient transaction retry execution is not implemented",
  "UTF-009": "the unified per-test lifecycle and driver entity boundary are not implemented",
  "UTF-010": "the first end-to-end standalone insertOne adapter is not implemented",
  "UTF-011": "the unified collection-read adapters are not implemented",
  "UTF-012": "the unified collection-write adapters are not implemented",
  "UTF-013": "unified command-event collection and matching are not implemented",
  "UTF-014": "unified failpoint configuration and cleanup are not implemented",
}

SPECIFICATION_OWNERS = {
  "auth": "ADV-008",
  "change-streams": "ADV-001",
  "client-side-encryption": "ADV-010",
  "mongodb-handshake": "REL-006",
  "retryable-reads": "RETRY-001",
  "retryable-writes": "RETRY-002",
  "transactions": "TXN-001",
  "transactions-convenient-api": "TXN-002",
}

READ_OPERATIONS = {
  "aggregate",
  "countDocuments",
  "distinct",
  "estimatedDocumentCount",
  "find",
  "findOne",
  "findOneAndDelete",
  "findOneAndReplace",
  "findOneAndUpdate",
}
WRITE_OPERATIONS = {
  "bulkWrite",
  "deleteMany",
  "deleteOne",
  "insertMany",
  "insertOne",
  "replaceOne",
  "updateMany",
  "updateOne",
}
MANAGEMENT_OPERATIONS = {
  "count",
  "createCollection",
  "createIndex",
  "dropCollection",
  "dropIndex",
  "listCollectionNames",
  "listCollectionObjects",
  "listCollections",
  "listDatabaseNames",
  "listDatabaseObjects",
  "listDatabases",
  "listIndexNames",
  "listIndexes",
  "mapReduce",
  "modifyCollection",
  "rename",
}

CSOT_SUPPORTED_OPERATIONS = READ_OPERATIONS | WRITE_OPERATIONS | {
  "abortTransaction",
  "commitTransaction",
  "createCollection",
  "createIndex",
  "dropCollection",
  "listCollectionNames",
  "listCollections",
  "listDatabaseNames",
  "listDatabases",
  "listIndexNames",
  "listIndexes",
  "runCommand",
  "startTransaction",
  "withTransaction",
}

CSOT_TEST_OPERATIONS = {
  "createEntities",
  "failPoint",
  "runOnThread",
  "wait",
  "waitForEvent",
  "waitForThread",
}

TEST_OVERRIDES = {
  identity: (value["activity"], None)
  for identity, value in EXECUTOR_TESTS.items()
}
TEST_OVERRIDES.update({
  "client-side-operations-timeout/tests/legacy-timeouts.json::test[3]": (
    "REL-005",
    "legacy wTimeoutMS requires the release unified write-concern mapping",
  ),
  "client-side-operations-timeout/tests/override-operation-timeoutMS.json::test[33]": (
    "REL-010",
    "listIndexNames requires the release unified operation-timeout adapter",
  ),
  "client-side-operations-timeout/tests/override-operation-timeoutMS.json::test[34]": (
    "REL-010",
    "listIndexNames requires the release unified operation-timeout adapter",
  ),
  "client-side-operations-timeout/tests/cursors.json::test[3]": (
    "ADV-011",
    "database aggregate is outside the v1 public collection adapter",
  ),
  "crud/tests/unified/aggregate-merge-errorResponse.json::test[1]": (
    "ADV-011",
    "database aggregate is outside the v1 public collection adapter",
  ),
  "crud/tests/unified/db-aggregate.json::test[1]": (
    "ADV-011",
    "database aggregate is outside the v1 public collection adapter",
  ),
  "crud/tests/unified/db-aggregate.json::test[2]": (
    "ADV-011",
    "database aggregate is outside the v1 public collection adapter",
  ),
  "read-write-concern/tests/operation/default-write-concern-3.4.json::test[4]": (
    "ADV-011",
    "legacy mapReduce is outside the v1 public API",
  ),
  "read-write-concern/tests/operation/default-write-concern-3.4.json::test[3]": (
    "REL-010",
    "dropIndex unified execution awaits v1 administration conformance",
  ),
  "versioned-api/tests/crud-api-version-1-strict.json::test[2]": (
    "ADV-011",
    "database aggregate is outside the v1 public API",
  ),
  "versioned-api/tests/crud-api-version-1.json::test[2]": (
    "ADV-011",
    "database aggregate is outside the v1 public API",
  ),
  "versioned-api/tests/crud-api-version-1.json::test[4]": (
    "ADV-007",
    "client bulkWrite is a post-v1 capability",
  ),
})

for fixture in (
  "bulkWrite-comment",
  "countDocuments-comment",
  "deleteMany-comment",
  "deleteOne-comment",
  "distinct-comment",
  "estimatedDocumentCount-comment",
  "find-comment",
  "findOneAndDelete-comment",
  "findOneAndReplace-comment",
  "findOneAndUpdate-comment",
  "insertMany-comment",
  "insertOne-comment",
  "replaceOne-comment",
  "updateMany-comment",
  "updateOne-comment",
):
  TEST_OVERRIDES[f"crud/tests/unified/{fixture}.json::test[3]"] = (
    "ADV-011",
    "the fixture targets server behavior before the v1 MongoDB 7.0 compatibility floor",
  )

TEST_OVERRIDES["crud/tests/unified/find-comment.json::test[5]"] = (
  "ADV-011",
  "the fixture targets server behavior before the v1 MongoDB 7.0 compatibility floor",
)

for fixture in (
  "aggregate-let",
  "bulkWrite-deleteMany-let",
  "bulkWrite-deleteOne-let",
  "bulkWrite-replaceOne-let",
  "bulkWrite-updateMany-let",
  "bulkWrite-updateOne-let",
  "deleteMany-let",
  "deleteOne-let",
  "find-let",
  "findOneAndDelete-let",
  "findOneAndReplace-let",
  "findOneAndUpdate-let",
  "replaceOne-let",
  "updateMany-let",
  "updateOne-let",
):
  TEST_OVERRIDES[f"crud/tests/unified/{fixture}.json::test[2]"] = (
    "ADV-011",
    "the fixture targets server behavior before the v1 MongoDB 7.0 compatibility floor",
  )

TEST_OVERRIDES["crud/tests/unified/aggregate-let.json::test[4]"] = (
  "ADV-011",
  "the fixture targets server behavior before the v1 MongoDB 7.0 compatibility floor",
)

for fixture, count, owner, reason in (
  ("count", 17, "ADV-011", "legacy count is outside the v1 public API"),
  ("changeStreams-client.watch", 17, "ADV-001", OWNER_REASONS["ADV-001"]),
  ("changeStreams-db.coll.watch", 17, "ADV-001", OWNER_REASONS["ADV-001"]),
  ("changeStreams-db.watch", 17, "ADV-001", OWNER_REASONS["ADV-001"]),
  ("gridfs-download", 17, "ADV-002", OWNER_REASONS["ADV-002"]),
  ("gridfs-downloadByName", 17, "ADV-002", OWNER_REASONS["ADV-002"]),
):
  base_count = min(count, 4)

  for index in range(1, base_count + 1):
    TEST_OVERRIDES[
      f"retryable-reads/tests/unified/{fixture}.json::test[{index}]"
    ] = (owner, reason)

  for index in range(1, count - base_count + 1):
    TEST_OVERRIDES[
      f"retryable-reads/tests/unified/{fixture}-serverErrors.json::test[{index}]"
    ] = (owner, reason)

for fixture, count, owner, reason in (
  ("handshakeError", 32, "REL-006", "handshake retry awaits release hardening"),
  ("mapReduce", 3, "ADV-011", "legacy mapReduce is outside the v1 public API"),
):
  for index in range(1, count + 1):
    TEST_OVERRIDES[
      f"retryable-reads/tests/unified/{fixture}.json::test[{index}]"
    ] = (owner, reason)

for fixture, count in (
  ("client-bulkWrite-clientErrors", 2),
  ("client-bulkWrite-serverErrors", 5),
):
  for index in range(1, count + 1):
    TEST_OVERRIDES[
      f"retryable-writes/tests/unified/{fixture}.json::test[{index}]"
    ] = ("ADV-007", OWNER_REASONS["ADV-007"])

for index in range(1, 21):
  TEST_OVERRIDES[
    f"retryable-writes/tests/unified/handshakeError.json::test[{index}]"
  ] = ("REL-006", "handshake retry awaits release hardening")

for index in range(1, 12):
  if index != 10:
    TEST_OVERRIDES[
      f"run-command/tests/unified/runCommand.json::test[{index}]"
    ] = (
      "REL-005",
      "general runCommand conformance awaits the v1 command adapter",
    )

for fixture, count in (
  ("backpressure-retryable-abort", 2),
  ("backpressure-retryable-commit", 2),
  ("backpressure-retryable-reads", 2),
  ("backpressure-retryable-writes", 3),
):
  for index in range(1, count + 1):
    TEST_OVERRIDES[
      f"transactions/tests/unified/{fixture}.json::test[{index}]"
    ] = ("ADV-009", OWNER_REASONS["ADV-009"])

for index in range(1, 4):
  TEST_OVERRIDES[
    f"transactions/tests/unified/client-bulkWrite.json::test[{index}]"
  ] = ("ADV-007", OWNER_REASONS["ADV-007"])

TEST_OVERRIDES["transactions/tests/unified/count.json::test[1]"] = (
  "ADV-011",
  "legacy count is outside the v1 public API",
)

for fixture, count in (
  ("mongos-pin-auto", 59),
  ("mongos-recovery-token-errorLabels", 1),
  ("mongos-recovery-token", 3),
  ("mongos-unpin", 7),
  ("pin-mongos", 9),
):
  for index in range(1, count + 1):
    TEST_OVERRIDES[
      f"transactions/tests/unified/{fixture}.json::test[{index}]"
    ] = ("ADV-005", OWNER_REASONS["ADV-005"])

for fixture in ("retryable-abort-handshake", "retryable-commit-handshake"):
  TEST_OVERRIDES[
    f"transactions/tests/unified/{fixture}.json::test[1]"
  ] = ("REL-006", "handshake retry awaits release hardening")

for fixture, count in (
  ("db-aggregate-rawdata", 2),
  ("db-aggregate-write-readPreference", 4),
):
  for index in range(1, count + 1):
    TEST_OVERRIDES[f"crud/tests/unified/{fixture}.json::test[{index}]"] = (
      "ADV-011",
      "database aggregate is outside the v1 public collection adapter",
    )

for operation in ("Delete", "Replace", "Update"):
  for index in (1, 2):
    TEST_OVERRIDES[
      f"crud/tests/unified/findOneAnd{operation}-hint-unacknowledged.json::test[{index}]"
    ] = (
      "ADV-011",
      "the pre-4.4 server requirement is outside the v1 compatibility matrix",
    )

for fixture in (
  "bulkWrite-deleteMany-hint-unacknowledged",
  "bulkWrite-deleteOne-hint-unacknowledged",
  "deleteMany-hint-unacknowledged",
  "deleteOne-hint-unacknowledged",
):
  for index in (1, 2):
    TEST_OVERRIDES[f"crud/tests/unified/{fixture}.json::test[{index}]"] = (
      "ADV-011",
      "the pre-4.4 server requirement is outside the v1 compatibility matrix",
    )

def classify_crud(test: dict[str, Any]) -> tuple[str, str]:
  requirements = test["requirements"]
  operations = set(requirements["operations"])
  special = set(requirements["special_operations"])

  if "clientBulkWrite" in operations:
    owner = "ADV-007"
  elif "session" in requirements["entities"] \
      or any(value.endswith(".session") for value in requirements["arguments"]):
    owner = "SES-001"
  elif "failPoint" in special or "targetedFailPoint" in special:
    owner = "UTF-014"
  elif requirements["events"]:
    owner = "REL-010"
  elif operations & MANAGEMENT_OPERATIONS:
    owner = "REL-010"
  elif operations & WRITE_OPERATIONS:
    owner = "UTF-012"
  elif operations & READ_OPERATIONS:
    owner = "UTF-011"
  elif not operations:
    owner = "UTF-009"
  else:
    raise run.CapabilityError(
      f"no CRUD capability owner for {test['id']}: {sorted(operations)}"
    )

  return owner, OWNER_REASONS[owner]


def classify_sdam(test: dict[str, Any]) -> tuple[str, str]:
  path = test["fixture"].lower()
  requirements = test["requirements"]
  topologies = set(requirements["topologies"])

  if requirements["logs"] or "/logging-" in path or "/backpressure-" in path:
    owner = "ADV-009"
  elif "load-balanced" in topologies or "loadbalanced" in path:
    owner = "ADV-006"
  elif {"sharded", "sharded-replicaset"} & topologies or "sharded-" in path:
    owner = "ADV-005"
  else:
    owner = "REL-006"

  return owner, OWNER_REASONS[owner]


def classify_csot(test: dict[str, Any]) -> tuple[str, str | None]:
  fixture = Path(test["fixture"]).name
  operations = set(test["requirements"]["operations"])
  entities = set(test["requirements"]["entities"])

  if "createChangeStream" in operations:
    return "ADV-001", OWNER_REASONS["ADV-001"]

  if "bucket" in entities:
    return (
      "ADV-002",
      "the CSOT case requires the post-v1 GridFS bucket entity adapter",
    )

  unsupported = operations - CSOT_SUPPORTED_OPERATIONS - CSOT_TEST_OPERATIONS

  if unsupported:
    if "count" in unsupported:
      owner = "ADV-011"
      reason = "legacy count is outside the v1 public API"
    elif unsupported <= {"dropIndex", "dropIndexes"}:
      owner = "REL-010"
      reason = "index operation timeout coverage awaits v1 administration conformance"
    else:
      owner = "REL-005"
      reason = "cursor operation timeout coverage awaits v1 command conformance"

    return (
      owner,
      reason + ": " + ", ".join(sorted(unsupported)),
    )

  if "aggregate on database" in test["description"]:
    return (
      "ADV-011",
      "database aggregate is outside the v1 public API",
    )

  if fixture == "retryability-legacy-timeouts.json":
    return (
      "REL-006",
      "legacy socket-timeout retry cases require release hardening of per-attempt transport deadlines",
    )

  if fixture in {
    "deprecated-options.json",
    "global-timeoutMS.json",
    "legacy-timeouts.json",
    "override-collection-timeoutMS.json",
    "override-database-timeoutMS.json",
    "override-operation-timeoutMS.json",
    "retryability-legacy-timeouts.json",
    "retryability-timeoutMS.json",
  }:
    return (
      "QUA-001",
      "the generated cross-operation CSOT matrix belongs to the v1 coverage and deterministic stress gate",
    )

  if fixture.startswith("tailable-"):
    return (
      "ADV-011",
      "tailable cursor unified adapters are outside the v1 public cursor surface",
    )

  if fixture == "change-streams.json":
    return "ADV-001", OWNER_REASONS["ADV-001"]

  if fixture.startswith("gridfs-") or {"upload", "download", "delete"} & operations:
    return "ADV-002", OWNER_REASONS["ADV-002"]

  if fixture == "bulkWrite.json" or "clientBulkWrite" in operations:
    return "ADV-007", OWNER_REASONS["ADV-007"]

  return "TIME-001", None


def classify_test(test: dict[str, Any]) -> tuple[str, str | None]:
  override = TEST_OVERRIDES.get(test["id"])

  if override:
    return override

  specification = test["fixture"].split("/", 1)[0]

  if specification == "client-side-operations-timeout":
    return classify_csot(test)

  if specification in SPECIFICATION_OWNERS:
    owner = SPECIFICATION_OWNERS[specification]
    return owner, OWNER_REASONS[owner]

  if specification == "crud":
    return classify_crud(test)

  if specification == "server-discovery-and-monitoring":
    return classify_sdam(test)

  if specification == "run-command":
    owner = "TXN-001" if test["fixture"].endswith("runCommand.json") else "REL-005"
    return owner, OWNER_REASONS[owner]

  if specification in {"read-write-concern", "versioned-api"}:
    return "REL-003", None

  raise run.CapabilityError(f"no classification rule for {test['id']}")


def generate() -> dict[str, object]:
  plan = json.loads(PLAN.read_text(encoding="utf-8"))
  commit = plan["references"]["specifications"]["commit"]
  discovered = run.discover_tests(run.DEFAULT_SOURCE)
  tests = {}

  for test in discovered:
    activity, reason = classify_test(test)
    tests[test["id"]] = {
      "activity": activity,
      "fingerprint": test["fingerprint"],
      "requirements": test["requirements"],
      "status": "runnable" if reason is None else "deferred_unsupported",
    }

    if reason is not None:
      tests[test["id"]]["reason"] = reason

  states = run.load_activity_states(PLAN, PROGRESS)
  classified = run.classify_tests(discovered, tests, states)
  run.validate_ratchets(classified, RATCHETS, RATCHETS["passed"])
  return {
    "ratchets": RATCHETS,
    "schema_version": 2,
    "specifications_commit": commit,
    "tests": tests,
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"
  except (OSError, json.JSONDecodeError, run.CapabilityError) as exc:
    print(f"unified capabilities: {exc}", file=sys.stderr)
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("unified capability manifest is stale", file=sys.stderr)
      return 1

    return 0

  OUTPUT.write_text(encoded, encoding="utf-8")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
