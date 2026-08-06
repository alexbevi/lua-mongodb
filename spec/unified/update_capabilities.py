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
    "AUTH-002",
    "SCRAM authentication and authenticated unified execution are not implemented",
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
    "API-003",
    "CRUD command and public API slices are not implemented",
  ),
  "mongodb-handshake": (
    "CMAP-001",
    "metadata append propagation requires public clients, CMAP, and event execution",
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
    "SDAM-001",
    "server discovery and monitoring are not implemented",
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

PATH_CLASSIFICATIONS = {
  "run-command/tests/unified/runCommand.json": (
    "TXN-002",
    "the public command API, sessions, and transaction execution are not implemented",
  ),
  "run-command/tests/unified/runCursorCommand.json": (
    "SES-001",
    "public cursor commands, pooling events, and session execution are not implemented",
  ),
}


def generate() -> dict[str, object]:
  plan = json.loads(PLAN.read_text(encoding="utf-8"))
  commit = plan["references"]["specifications"]["commit"]
  fixtures = {}

  for path in run.discover_fixtures(run.DEFAULT_SOURCE):
    specification = path.split("/", 1)[0]

    if path in PATH_CLASSIFICATIONS:
      activity, reason = PATH_CLASSIFICATIONS[path]
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
