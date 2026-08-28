#!/usr/bin/env python3
"""Project conformance evidence into the README compatibility table."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import re
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LEDGER = ROOT / "spec" / "conformance" / "ledger.json"
DEFAULT_CATALOG = ROOT / "spec" / "conformance" / "catalog.json"
DEFAULT_README = ROOT / "README.md"
DEFAULT_SPECIFICATIONS = ROOT / "planning" / "specifications" / "source"
BEGIN = "<!-- BEGIN SPEC CONFORMANCE -->"
END = "<!-- END SPEC CONFORMANCE -->"
SPECIFICATIONS_URL = "https://alexbevi.com/specifications/"
SUPPORTED_SERVER_FLOOR = (7, 0, 0)
OLD_SERVER_ONLY_STATUS = "old_server_only"

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
  )),
)

SPECIFICATION_DOCUMENTS = {
  "auth": "auth/auth.md",
  "bson-binary-vector": "bson-binary-vector/bson-binary-vector.md",
  "bson-corpus": "bson-corpus/bson-corpus.md",
  "causal-consistency": "causal-consistency/causal-consistency.md",
  "change-streams": "change-streams/change-streams.md",
  "client-backpressure": (
    "connection-monitoring-and-pooling/connection-monitoring-and-pooling.md"
  ),
  "client-side-encryption": "client-side-encryption/client-side-encryption.md",
  "client-side-operations-timeout": (
    "client-side-operations-timeout/client-side-operations-timeout.md"
  ),
  "collection-management": "enumerate-collections/enumerate-collections.md",
  "command-logging-and-monitoring": (
    "command-logging-and-monitoring/command-logging-and-monitoring.md"
  ),
  "compression": "compression/OP_COMPRESSED.md",
  "connection-monitoring-and-pooling": (
    "connection-monitoring-and-pooling/connection-monitoring-and-pooling.md"
  ),
  "connection-string": "connection-string/connection-string-spec.md",
  "crud": "crud/crud.md",
  "gridfs": "gridfs/gridfs-spec.md",
  "index-management": "index-management/index-management.md",
  "initial-dns-seedlist-discovery": (
    "initial-dns-seedlist-discovery/initial-dns-seedlist-discovery.md"
  ),
  "load-balancers": "load-balancers/load-balancers.md",
  "logging": "logging/logging.md",
  "max-staleness": "max-staleness/max-staleness.md",
  "mongodb-handshake": "mongodb-handshake/handshake.md",
  "ocsp-support": "ocsp-support/ocsp-support.md",
  "open-telemetry": "open-telemetry/open-telemetry.md",
  "polling-srv-records-for-mongos-discovery": (
    "polling-srv-records-for-mongos-discovery/"
    "polling-srv-records-for-mongos-discovery.md"
  ),
  "read-write-concern": "read-write-concern/read-write-concern.md",
  "retryable-reads": "retryable-reads/retryable-reads.md",
  "retryable-writes": "retryable-writes/retryable-writes.md",
  "run-command": "run-command/run-command.md",
  "server-discovery-and-monitoring": (
    "server-discovery-and-monitoring/server-discovery-and-monitoring.md"
  ),
  "server-selection": "server-selection/server-selection.md",
  "sessions": "sessions/driver-sessions.md",
  "socks5-support": "socks5-support/socks5.md",
  "transactions": "transactions/transactions.md",
  "transactions-convenient-api": (
    "transactions-convenient-api/transactions-convenient-api.md"
  ),
  "unified-test-format": "unified-test-format/unified-test-format.md",
  "uri-options": "uri-options/uri-options.md",
  "versioned-api": "versioned-api/versioned-api.md",
}

CATALOG_PROSE_SUITES = frozenset({
  "compression",
  "logging",
  "ocsp-support",
  "polling-srv-records-for-mongos-discovery",
  "socks5-support",
})

CATALOG_MIXED_SUITES = frozenset({"auth", "gridfs"})
CATALOG_PROJECTED_SUITES = CATALOG_PROSE_SUITES | CATALOG_MIXED_SUITES

CATALOG_REQUIREMENT_STATUSES = frozenset({
  "deferred_unsupported",
  "excluded",
  "no_machine_cases",
  "not_applicable",
  "passed",
  "unsupported",
})

NON_EXECUTION_STATUSES = frozenset({
  "no_machine_cases",
  "not_applicable",
  OLD_SERVER_ONLY_STATUS,
  "unsupported",
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


def _server_version(value: object, identity: str) -> tuple[int, int, int]:
  if (
    not isinstance(value, str)
    or not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value)
  ):
    raise ReadmeCompatibilityError(
      f"unified fixture has an invalid maxServerVersion: {identity}"
    )

  components = [int(component) for component in value.split(".")]
  components.extend([0] * (3 - len(components)))
  return tuple(components)


def _requirements_are_old_server_only(
  requirements: object,
  identity: str,
) -> bool:
  if requirements is None:
    return False

  if not isinstance(requirements, list):
    raise ReadmeCompatibilityError(
      f"unified fixture runOnRequirements must be an array: {identity}"
    )

  if not requirements:
    return False

  for requirement in requirements:
    if not isinstance(requirement, dict):
      raise ReadmeCompatibilityError(
        f"unified fixture runOnRequirements entry must be an object: {identity}"
      )

    maximum = requirement.get("maxServerVersion")

    if maximum is None:
      return False

    if _server_version(maximum, identity) >= SUPPORTED_SERVER_FLOOR:
      return False

  return True


def _is_old_server_only_fixture(
  identity: str,
  case: dict[str, Any],
  specifications_path: Path,
  fixture_documents: dict[Path, dict[str, Any]],
) -> bool:
  if case.get("format") != "unified":
    return False

  match = re.search(r"::test\[(\d+)\]$", identity)

  if match is None:
    return False

  source = case.get("source")

  if not isinstance(source, str):
    raise ReadmeCompatibilityError(
      f"unified conformance case has no source: {identity}"
    )

  source_path = specifications_path / source

  if source_path not in fixture_documents:
    fixture_documents[source_path] = _read_json(
      source_path,
      f"unified fixture {source}",
    )

  document = fixture_documents[source_path]
  tests = document.get("tests")
  index = int(match.group(1))

  if not isinstance(tests, list) or index < 1 or index > len(tests):
    raise ReadmeCompatibilityError(
      f"unified fixture test index is invalid: {identity}"
    )

  test = tests[index - 1]

  if not isinstance(test, dict):
    raise ReadmeCompatibilityError(
      f"unified fixture test must be an object: {identity}"
    )

  return (
    _requirements_are_old_server_only(
      document.get("runOnRequirements"),
      identity,
    )
    or _requirements_are_old_server_only(
      test.get("runOnRequirements"),
      identity,
    )
  )


def suite_counts(
  path: Path = DEFAULT_LEDGER,
  catalog_path: Path = DEFAULT_CATALOG,
  specifications_path: Path = DEFAULT_SPECIFICATIONS,
) -> dict[str, Counter[str]]:
  ledger = _read_json(path, "conformance ledger")

  cases = ledger.get("cases")

  if not isinstance(cases, dict):
    raise ReadmeCompatibilityError("conformance ledger cases must be an object")

  counts: dict[str, Counter[str]] = defaultdict(Counter)
  fixture_documents: dict[Path, dict[str, Any]] = {}

  for identity, case in cases.items():
    suite = case.get("suite")
    status = case.get("status")

    if not isinstance(suite, str) or not isinstance(status, str):
      raise ReadmeCompatibilityError(
        f"conformance case {identity} has no suite or status"
      )

    if _is_old_server_only_fixture(
      identity,
      case,
      specifications_path,
      fixture_documents,
    ):
      status = OLD_SERVER_ONLY_STATUS

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

  for suite in CATALOG_MIXED_SUITES:
    metadata = suites.get(suite)

    if not isinstance(metadata, dict) or metadata.get("has_machine_fixtures") is not True:
      raise ReadmeCompatibilityError(
        f"catalog mixed suite is missing machine fixtures: {suite}"
      )

    if suite not in counts:
      raise ReadmeCompatibilityError(
        f"catalog mixed suite has no ledger cases: {suite}"
      )

  for identity, requirement in requirements.items():
    if not isinstance(requirement, dict):
      raise ReadmeCompatibilityError(
        f"catalog requirement must be an object: {identity}"
      )

    suite = requirement.get("suite")

    if suite not in CATALOG_PROJECTED_SUITES:
      continue

    status = requirement.get("status")

    if status not in CATALOG_REQUIREMENT_STATUSES:
      raise ReadmeCompatibilityError(
        f"catalog requirement has an invalid status: {identity}"
      )

    counts[suite][status] += 1

  missing_requirements = sorted(
    suite for suite in CATALOG_PROJECTED_SUITES if not counts[suite]
  )

  if missing_requirements:
    raise ReadmeCompatibilityError(
      f"catalog prose suites have no requirements: {missing_requirements}"
    )

  return dict(counts)


def status_marker(counts: dict[str, int]) -> str:
  passed = counts.get("passed", 0)
  incomplete = sum(
    count for status, count in counts.items()
    if status != "passed" and status not in NON_EXECUTION_STATUSES
  )

  if passed > 0 and incomplete == 0:
    return "🟢"

  if passed > 0:
    return "🟡"

  if counts.get("unsupported", 0) > 0:
    return "⚪"

  if incomplete > 0:
    return "🔴"

  return "⚪"


def supported_percentage(counts: dict[str, int]) -> str:
  total = sum(
    count for status, count in counts.items()
    if status not in NON_EXECUTION_STATUSES
  )

  if total == 0:
    return "N/A"

  return f"{counts.get('passed', 0) / total * 100:.1f}%"


def specification_url(suite: str) -> str:
  document = SPECIFICATION_DOCUMENTS[suite]

  if not document.endswith(".md"):
    raise ReadmeCompatibilityError(
      f"specification document is not Markdown: {document}"
    )

  return f"{SPECIFICATIONS_URL}{document[:-3]}.html"


def marked_percentage(counts: dict[str, int]) -> str:
  percentage = supported_percentage(counts)

  if counts.get(OLD_SERVER_ONLY_STATUS, 0) == 0:
    return percentage

  return f"{percentage}\\*"


def old_server_note(counts: dict[str, Counter[str]]) -> str | None:
  labels = {
    suite: label
    for _, entries in DRIVER_LAYERS
    for suite, label in entries
  }
  affected = sorted(
    (
      (outcomes[OLD_SERVER_ONLY_STATUS], labels[suite])
      for suite, outcomes in counts.items()
      if outcomes[OLD_SERVER_ONLY_STATUS] > 0
    ),
    key=lambda item: (-item[0], item[1].lower()),
  )

  if not affected:
    return None

  total = sum(count for count, _ in affected)
  suites = ", ".join(
    f"{label} ({count})"
    for count, label in affected[:-1]
  )

  if len(affected) > 1:
    suites = f"{suites}, and {affected[-1][1]} ({affected[-1][0]})"
  else:
    suites = f"{affected[0][1]} ({affected[0][0]})"

  return (
    "> [!NOTE]\n"
    f"> \\* The marked percentages skip {total} upstream fixtures because "
    "their `runOnRequirements` restrict them to MongoDB versions older than "
    f"the supported 7.0 floor. The affected suites are {suites}. These fixtures "
    "remain classified in the conformance ledger but do not count toward the "
    "marked suite percentages or the total."
  )


def render_table(
  path: Path = DEFAULT_LEDGER,
  catalog_path: Path = DEFAULT_CATALOG,
  specifications_path: Path = DEFAULT_SPECIFICATIONS,
) -> str:
  counts = suite_counts(path, catalog_path, specifications_path)
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

  if set(SPECIFICATION_DOCUMENTS) != mapped:
    missing = sorted(mapped - set(SPECIFICATION_DOCUMENTS))
    stale = sorted(set(SPECIFICATION_DOCUMENTS) - mapped)
    raise ReadmeCompatibilityError(
      f"specification links differ from onion rows; "
      f"missing={missing}, stale={stale}"
    )

  catalog_documents = {
    document
    for metadata in catalog_suites.values()
    if isinstance(metadata, dict)
    for document in metadata.get("documents", [])
    if isinstance(document, str)
  }
  unknown_documents = sorted(set(SPECIFICATION_DOCUMENTS.values()) - catalog_documents)

  if unknown_documents:
    raise ReadmeCompatibilityError(
      f"specification links are absent from the accepted catalog: {unknown_documents}"
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
    "| Driver layer | Specification suite | Status | Tracked support % |",
    "| --- | --- | :---: | ---: |",
  ]
  total_counts: Counter[str] = Counter()

  for layer, entries in DRIVER_LAYERS:
    for suite, label in entries:
      total_counts.update(counts[suite])
      lines.append(
        f"| {layer} | [{label}]({specification_url(suite)}) | "
        f"{status_marker(counts[suite])} | "
        f"{marked_percentage(counts[suite])} |"
      )

  lines.append(
    f"|  | **Total** |  | **{marked_percentage(total_counts)}** |"
  )

  note = old_server_note(counts)

  if note is not None:
    lines.extend(("", note))

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
  parser.add_argument(
    "--specifications",
    type=Path,
    default=DEFAULT_SPECIFICATIONS,
  )
  arguments = parser.parse_args(argv)

  try:
    current = arguments.readme.read_text(encoding="utf-8")
    expected = updated_readme(
      current,
      render_table(
        arguments.ledger,
        arguments.catalog,
        arguments.specifications,
      ),
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
