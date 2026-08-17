#!/usr/bin/env python3
"""Project conformance evidence into the README compatibility table."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
DEFAULT_CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
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
    ("ocsp-support", "OCSP support"),
    ("compression", "Wire compression"),
    ("socks5-support", "SOCKS5 proxy support"),
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
    ("polling-srv-records-for-mongos-discovery", "Periodic SRV polling"),
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
    ("logging", "Standardized logging"),
    ("client-backpressure", "Client backpressure"),
    ("open-telemetry", "OpenTelemetry"),
  )),
  ("Testability", (
    ("unified-test-format", "Unified test format"),
    ("atlas-sfp-testing", "Atlas SFP testing"),
  )),
)

CATALOG_PROSE_SUITES = frozenset({
  "atlas-sfp-testing",
  "compression",
  "logging",
  "ocsp-support",
  "polling-srv-records-for-mongos-discovery",
  "socks5-support",
})

CATALOG_REQUIREMENT_STATUSES = frozenset({
  "deferred_unsupported",
  "excluded",
  "no_machine_cases",
  "not_applicable",
  "passed",
})


class ReadmeCompatibilityError(ValueError):
  """Raised when conformance evidence cannot produce a complete projection."""


def _read_json(path: Path, description: str) -> dict[str, Any]:
  try:
    value = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ReadmeCompatibilityError(f"cannot read {description}: {exc}") from exc

  if not isinstance(value, dict):
    raise ReadmeCompatibilityError(f"{description} must be an object")

  return value


def suite_counts(
  path: Path = DEFAULT_LEDGER,
  catalog_path: Path = DEFAULT_CATALOG,
) -> dict[str, Counter[str]]:
  ledger = _read_json(path, "conformance ledger")

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

  catalog = _read_json(catalog_path, "accepted specification catalog")
  suites = catalog.get("suites")
  requirements = catalog.get("requirements")

  if not isinstance(suites, dict) or not isinstance(requirements, dict):
    raise ReadmeCompatibilityError(
      "accepted specification catalog suites and requirements must be objects"
    )

  for suite in CATALOG_PROSE_SUITES:
    metadata = suites.get(suite)

    if not isinstance(metadata, dict) or metadata.get("has_machine_fixtures") is not False:
      raise ReadmeCompatibilityError(
        f"catalog prose suite is missing or has machine fixtures: {suite}"
      )

    if suite in counts:
      raise ReadmeCompatibilityError(
        f"catalog prose suite also has ledger cases: {suite}"
      )

  for identity, requirement in requirements.items():
    if not isinstance(requirement, dict):
      raise ReadmeCompatibilityError(
        f"catalog requirement must be an object: {identity}"
      )

    suite = requirement.get("suite")

    if suite not in CATALOG_PROSE_SUITES:
      continue

    status = requirement.get("status")

    if status not in CATALOG_REQUIREMENT_STATUSES:
      raise ReadmeCompatibilityError(
        f"catalog requirement has an invalid status: {identity}"
      )

    counts[suite][status] += 1

  missing_requirements = sorted(
    suite for suite in CATALOG_PROSE_SUITES if not counts[suite]
  )

  if missing_requirements:
    raise ReadmeCompatibilityError(
      f"catalog prose suites have no requirements: {missing_requirements}"
    )

  return dict(counts)


def status_marker(counts: dict[str, int]) -> str:
  passed = counts.get("passed", 0)
  incomplete = sum(count for status, count in counts.items() if status != "passed")

  if passed > 0 and incomplete == 0:
    return "🟢"

  if passed > 0:
    return "🟡"

  return "🔴"


def passing_percentage(counts: dict[str, int]) -> str:
  total = sum(counts.values())

  if total == 0:
    raise ReadmeCompatibilityError(
      "cannot calculate a passing percentage without tracked cases"
    )

  return f"{counts.get('passed', 0) / total * 100:.1f}%"


def render_table(
  path: Path = DEFAULT_LEDGER,
  catalog_path: Path = DEFAULT_CATALOG,
) -> str:
  counts = suite_counts(path, catalog_path)
  mapped_layers = {
    suite: layer
    for layer, entries in DRIVER_LAYERS
    for suite, _ in entries
  }
  mapped = set(mapped_layers)
  discovered = set(counts)

  if mapped != discovered:
    missing = sorted(discovered - mapped)
    stale = sorted(mapped - discovered)
    raise ReadmeCompatibilityError(
      f"onion mapping differs from conformance evidence; "
      f"unmapped={missing}, stale={stale}"
    )

  catalog = _read_json(catalog_path, "accepted specification catalog")
  catalog_suites = catalog.get("suites")

  if not isinstance(catalog_suites, dict):
    raise ReadmeCompatibilityError(
      "accepted specification catalog suites must be an object"
    )

  mismatched_layers = sorted(
    suite for suite in CATALOG_PROSE_SUITES
    if not isinstance(catalog_suites.get(suite), dict)
    or catalog_suites[suite].get("layer") != mapped_layers.get(suite)
  )

  if mismatched_layers:
    raise ReadmeCompatibilityError(
      f"onion rows differ from the accepted specification catalog: {mismatched_layers}"
    )

  lines = [
    "| Driver layer | Specification suite | Status | Tests Passing % |",
    "| --- | --- | :---: | ---: |",
  ]

  for layer, entries in DRIVER_LAYERS:
    for suite, label in entries:
      lines.append(
        f"| {layer} | {label} | {status_marker(counts[suite])} | "
        f"{passing_percentage(counts[suite])} |"
      )

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
  parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
  parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
  parser.add_argument("--readme", type=Path, default=DEFAULT_README)
  arguments = parser.parse_args(argv)

  try:
    current = arguments.readme.read_text(encoding="utf-8")
    expected = updated_readme(
      current,
      render_table(arguments.ledger, arguments.catalog),
    )
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
