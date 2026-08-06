#!/usr/bin/env python3
"""Regenerate the checked-in unified fixture capability manifest."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.unified import run  # noqa: E402


PLAN = ROOT / "planning" / "plan.json"
OUTPUT = ROOT / "spec" / "unified" / "capabilities.json"

CLASSIFICATIONS = {
  "auth": (
    "ADV-008",
    "the pinned authentication fixture requires post-v1 OIDC authentication",
  ),
  "change-streams": (
    "ADV-001",
    "change streams are a post-v1 capability",
  ),
  "client-side-encryption": (
    "POST-V1-DESIGN",
    "client-side field-level and queryable encryption require a separate design",
  ),
  "crud": (
    "REL-001",
    "the fixture requires a CRUD operation outside the current collection API or "
    "the live unified execution bridge completed by REL-001",
  ),
  "mongodb-handshake": (
    "SDAM-002",
    "pool lifecycle is implemented; metadata append propagation requires the public "
    "pooled client, handshake event bridge, and multi-connection execution owned by SDAM-002",
  ),
  "retryable-reads": (
    "RET-001",
    "retryable reads are not implemented",
  ),
  "retryable-writes": (
    "RET-002",
    "retryable writes are not implemented",
  ),
  "server-discovery-and-monitoring": (
    "SDAM-002",
    "immutable phase-one descriptions and transitions are implemented; live monitor "
    "scheduling, replica-set discovery, SDAM events, failpoints, and public multi-seed "
    "execution are owned by SDAM-002",
  ),
  "transactions": (
    "TXN-002",
    "transaction execution is not implemented",
  ),
  "transactions-convenient-api": (
    "TXN-003",
    "the convenient transaction API is not implemented",
  ),
}

LIVE_CRUD_REASON = (
  "live unified CRUD entities, server requirements, command-event matching, "
  "failpoints, and outcome execution are deferred to the REL-001 conformance bridge; "
  "command models are covered by unit, loopback, and real-server integration tests"
)

PATH_CLASSIFICATIONS = {
  "crud/tests/unified/bypassDocumentValidation.json": (
    "REL-001",
    LIVE_CRUD_REASON,
  ),
  "crud/tests/unified/create-null-ids.json": (
    "ADV-007",
    "the fixture includes post-v1 client bulkWrite in addition to implemented collection writes",
  ),
  "run-command/tests/unified/runCommand.json": (
    "TXN-002",
    "the public command API, sessions, and transaction execution are not implemented",
  ),
  "run-command/tests/unified/runCursorCommand.json": (
    "SES-001",
    "public cursor commands, pooling events, and session execution are not implemented",
  ),
}

CORE_CRUD_PREFIXES = (
  "crud/tests/unified/aggregate",
  "crud/tests/unified/countDocuments",
  "crud/tests/unified/deleteMany",
  "crud/tests/unified/deleteOne",
  "crud/tests/unified/distinct",
  "crud/tests/unified/estimatedDocumentCount",
  "crud/tests/unified/find-",
  "crud/tests/unified/find.json",
  "crud/tests/unified/findOne",
  "crud/tests/unified/insertOne",
  "crud/tests/unified/replaceOne",
  "crud/tests/unified/updateMany",
  "crud/tests/unified/updateOne",
)
COLLECTION_BULK_PREFIXES = (
  "crud/tests/unified/bulkWrite",
  "crud/tests/unified/insertMany",
)
CLIENT_BULK_PREFIX = "crud/tests/unified/client-bulkWrite"
LEGACY_COUNT_PREFIXES = (
  "crud/tests/unified/count-",
  "crud/tests/unified/count.json",
)
DATABASE_AGGREGATE_PREFIX = "crud/tests/unified/db-aggregate"


def generate() -> dict[str, object]:
  plan = json.loads(PLAN.read_text(encoding="utf-8"))
  commit = plan["references"]["specifications"]["commit"]
  fixtures = {}

  for path in run.discover_fixtures(run.DEFAULT_SOURCE):
    specification = path.split("/", 1)[0]

    if path in PATH_CLASSIFICATIONS:
      activity, reason = PATH_CLASSIFICATIONS[path]
    elif path.startswith(CORE_CRUD_PREFIXES):
      activity, reason = "REL-001", LIVE_CRUD_REASON
    elif path.startswith(COLLECTION_BULK_PREFIXES):
      activity, reason = "REL-001", LIVE_CRUD_REASON
    elif path.startswith(CLIENT_BULK_PREFIX):
      activity = "ADV-007"
      reason = "client bulkWrite is a post-v1 capability"
    elif path.startswith(LEGACY_COUNT_PREFIXES):
      activity = "REL-001"
      reason = (
        "the fixture mixes supported count helpers with the deprecated count operation, "
        "which v1 intentionally does not expose; partial execution awaits REL-001"
      )
    elif path.startswith(DATABASE_AGGREGATE_PREFIX):
      activity = "REL-001"
      reason = "database-level aggregate and its live unified execution bridge await REL-001"
    elif specification in CLASSIFICATIONS:
      activity, reason = CLASSIFICATIONS[specification]
    else:
      raise run.CapabilityError(f"no classification rule for specification: {specification}")

    fixtures[path] = {
      "activity": activity,
      "reason": reason,
      "status": "deferred",
    }

  return {
    "fixtures": fixtures,
    "schema_version": 1,
    "specifications_commit": commit,
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)
  encoded = json.dumps(generate(), indent=2, sort_keys=True) + "\n"

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("unified capability manifest is stale", file=sys.stderr)
      return 1

    return 0

  OUTPUT.write_text(encoded, encoding="utf-8")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
