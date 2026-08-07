#!/usr/bin/env python3
"""Project the conformance ledger into the README compatibility table."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
DEFAULT_README = ROOT / "README.md"
BEGIN = "<!-- BEGIN SPEC CONFORMANCE -->"
END = "<!-- END SPEC CONFORMANCE -->"

DRIVER_LAYERS = (
  ("Serialization", (
    ("bson-corpus", "BSON corpus"),
    ("bson-binary-vector", "BSON binary vector"),
  )),
  ("Communication", (
    ("connection-string", "Connection string"),
    ("uri-options", "URI options"),
    ("mongodb-handshake", "Handshake metadata propagation"),
    ("initial-dns-seedlist-discovery", "Initial DNS seedlist discovery"),
    ("run-command", "Command execution"),
  )),
  ("Connectivity", (
    ("server-discovery-and-monitoring", "Server discovery and monitoring"),
    ("connection-monitoring-and-pooling", "Connection monitoring and pooling"),
    ("load-balancers", "Load balancer support"),
  )),
  ("Authentication", (
    ("auth", "Authentication options and additional mechanisms"),
  )),
  ("Availability", (
    ("server-selection", "Server selection"),
    ("max-staleness", "Max staleness"),
  )),
  ("Resilience", (
    ("retryable-reads", "Retryable reads"),
    ("retryable-writes", "Retryable writes"),
    ("client-side-operations-timeout", "Client-side operations timeout"),
    ("sessions", "Sessions"),
    ("causal-consistency", "Causal consistency"),
    ("transactions", "Transactions"),
    ("transactions-convenient-api", "Convenient transactions API"),
  )),
  ("Programmability", (
    ("crud", "CRUD"),
    ("collection-management", "Collection management"),
    ("index-management", "Index management"),
    ("read-write-concern", "Read/write concern"),
    ("change-streams", "Change streams"),
    ("gridfs", "GridFS"),
    ("versioned-api", "Stable API"),
    ("client-side-encryption", "Client-side encryption"),
  )),
  ("Observability", (
    ("command-logging-and-monitoring", "Command logging and monitoring"),
    ("client-backpressure", "Client backpressure"),
    ("open-telemetry", "OpenTelemetry"),
  )),
  ("Testability", (
    ("unified-test-format", "Unified test format"),
  )),
)


class ReadmeCompatibilityError(ValueError):
  """Raised when the ledger cannot produce a complete README projection."""


def suite_counts(path: Path = DEFAULT_LEDGER) -> dict[str, Counter[str]]:
  try:
    ledger = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ReadmeCompatibilityError(f"cannot read conformance ledger: {exc}") from exc

  cases = ledger.get("cases")

  if not isinstance(cases, dict):
    raise ReadmeCompatibilityError("conformance ledger cases must be an object")

  counts: dict[str, Counter[str]] = defaultdict(Counter)

  for identity, case in cases.items():
    suite = case.get("suite")
    status = case.get("status")

    if not isinstance(suite, str) or not isinstance(status, str):
      raise ReadmeCompatibilityError(
        f"conformance case {identity} has no suite or status"
      )

    counts[suite][status] += 1

  return dict(counts)


def status_marker(counts: dict[str, int]) -> str:
  passed = counts.get("passed", 0)
  incomplete = sum(count for status, count in counts.items() if status != "passed")

  if passed > 0 and incomplete == 0:
    return "🟢"

  if passed > 0:
    return "🟡"

  return "🔴"


def render_table(path: Path = DEFAULT_LEDGER) -> str:
  counts = suite_counts(path)
  mapped = {
    suite
    for _, entries in DRIVER_LAYERS
    for suite, _ in entries
  }
  discovered = set(counts)

  if mapped != discovered:
    missing = sorted(discovered - mapped)
    stale = sorted(mapped - discovered)
    raise ReadmeCompatibilityError(
      f"onion mapping differs from ledger; unmapped={missing}, stale={stale}"
    )

  lines = [
    "| Driver layer | Specification suite | Status |",
    "| --- | --- | :---: |",
  ]

  for layer, entries in DRIVER_LAYERS:
    for suite, label in entries:
      lines.append(f"| {layer} | {label} | {status_marker(counts[suite])} |")

  return "\n".join(lines)


def updated_readme(readme: str, table: str) -> str:
  if readme.count(BEGIN) != 1 or readme.count(END) != 1:
    raise ReadmeCompatibilityError(
      "README must contain exactly one generated conformance section"
    )

  before, remainder = readme.split(BEGIN, 1)
  _, after = remainder.split(END, 1)
  return f"{before}{BEGIN}\n{table}\n{END}{after}"


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
  parser.add_argument("--readme", type=Path, default=DEFAULT_README)
  arguments = parser.parse_args(argv)

  try:
    current = arguments.readme.read_text(encoding="utf-8")
    expected = updated_readme(current, render_table(arguments.ledger))
  except (OSError, ReadmeCompatibilityError) as exc:
    print(f"README compatibility: {exc}", file=sys.stderr)
    return 2

  if arguments.check:
    if current != expected:
      print(
        "README compatibility: table is stale; run "
        "python3 planning/update_readme_compatibility.py",
        file=sys.stderr,
      )
      return 1

    print("README compatibility: conformance projection is current")
    return 0

  arguments.readme.write_text(expected, encoding="utf-8")
  print("README compatibility: updated conformance projection")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
