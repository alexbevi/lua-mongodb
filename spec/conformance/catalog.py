#!/usr/bin/env python3
"""Generate the catalog of accepted MongoDB specification documents."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "planning" / "specifications" / "source"
PLAN = ROOT / "planning" / "plan.json"
PROGRESS = ROOT / "planning" / "progress.json"
LAYERS = ROOT / "spec" / "conformance" / "onion_layers.json"
REQUIREMENTS = ROOT / "spec" / "conformance" / "prose_requirements.json"
OUTPUT = ROOT / "spec" / "conformance" / "catalog.json"
ACCEPTED = re.compile(r"^\s*[-*] Status: Accepted\s*$", re.MULTILINE)
LAYERS_IN_ORDER = (
  "Serialization",
  "Communication",
  "Connectivity",
  "Authentication",
  "Availability",
  "Resilience",
  "Programmability",
  "Observability",
  "Testability",
)
VALID_REQUIREMENT_STATUSES = {
  "deferred_unsupported",
  "excluded_scope",
  "passed",
}


class CatalogError(ValueError):
  """Raised when accepted specifications and their catalog diverge."""


def _fingerprint(path: Path) -> str:
  return hashlib.sha256(path.read_bytes()).hexdigest()


def discover_accepted_documents(
  source: Path = SOURCE,
) -> dict[str, dict[str, str]]:
  """Return every Markdown or RST document with Accepted status metadata."""
  documents = {}

  for path in sorted(source.rglob("*")):
    if not path.is_file() or path.suffix.lower() not in {".md", ".rst"}:
      continue

    content = path.read_text(encoding="utf-8")

    if not ACCEPTED.search(content):
      continue

    relative = path.relative_to(source).as_posix()
    documents[relative] = {
      "fingerprint": _fingerprint(path),
      "source": relative,
      "suite": relative.split("/", 1)[0],
    }

  return documents


def _load_layers(path: Path = LAYERS) -> dict[str, str]:
  try:
    manifest = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CatalogError(f"could not load onion layer manifest: {exc}") from exc

  if manifest.get("schema_version") != 1:
    raise CatalogError("onion layer manifest schema_version must be 1")

  suites = manifest.get("suites")

  if not isinstance(suites, dict):
    raise CatalogError("onion layer manifest suites must be an object")

  for suite, layer in suites.items():
    if not isinstance(suite, str) or not suite:
      raise CatalogError("onion layer manifest has an invalid suite identity")

    if layer not in LAYERS_IN_ORDER:
      raise CatalogError(f"onion layer manifest has an invalid layer for {suite}")

  return suites


def _specifications_commit(path: Path = PLAN) -> str:
  try:
    plan = json.loads(path.read_text(encoding="utf-8"))
    commit = plan["references"]["specifications"]["commit"]
  except (OSError, json.JSONDecodeError, KeyError, TypeError) as exc:
    raise CatalogError(f"could not load pinned specifications commit: {exc}") from exc

  if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise CatalogError("pinned specifications commit must be a 40-character SHA")

  return commit


def _load_activities(
  plan_path: Path = PLAN,
  progress_path: Path = PROGRESS,
) -> dict[str, dict[str, str]]:
  try:
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    progress = json.loads(progress_path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CatalogError(f"could not load roadmap state: {exc}") from exc

  records = progress.get("activities", {})
  return {
    activity["id"]: {
      "scope": activity["milestone"],
      "status": records.get(activity["id"], {}).get("status", "pending"),
    }
    for activity in plan.get("activities", [])
  }


def _load_requirement_manifest(path: Path = REQUIREMENTS) -> dict[str, dict[str, Any]]:
  try:
    manifest = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise CatalogError(f"could not load prose requirement manifest: {exc}") from exc

  if manifest.get("schema_version") != 1:
    raise CatalogError("prose requirement manifest schema_version must be 1")

  requirements = manifest.get("requirements")

  if not isinstance(requirements, dict):
    raise CatalogError("prose requirement manifest requirements must be an object")

  return requirements


def _has_machine_fixtures(source: Path, suite: str) -> bool:
  tests = source / suite / "tests"

  return any(
    path.is_file() and path.suffix.lower() in {".json", ".yaml", ".yml"}
    for path in tests.rglob("*")
  ) if tests.is_dir() else False


def _generate_requirements(
  documents: dict[str, dict[str, str]],
  suites: dict[str, dict[str, Any]],
  specifications_commit: str,
) -> dict[str, dict[str, Any]]:
  classifications = _load_requirement_manifest()
  activities = _load_activities()
  prose_sources = {
    identity for identity, document in documents.items()
    if not suites[document["suite"]]["has_machine_fixtures"]
  }

  if prose_sources != set(classifications):
    missing = sorted(prose_sources - set(classifications))
    stale = sorted(set(classifications) - prose_sources)
    raise CatalogError(
      f"prose-only documents differ from requirement manifest; "
      f"unclassified={missing}, stale={stale}"
    )

  required_fields = {
    "activity",
    "last_execution",
    "reason",
    "required_environment",
    "runner",
    "status",
  }
  requirements = {}

  for source in sorted(prose_sources):
    classification = classifications[source]

    if not isinstance(classification, dict) or set(classification) != required_fields:
      raise CatalogError(f"prose requirement has malformed fields: {source}")

    activity = classification["activity"]
    status = classification["status"]

    if activity not in activities:
      raise CatalogError(f"prose requirement has unknown owner {activity}: {source}")

    if status not in VALID_REQUIREMENT_STATUSES:
      raise CatalogError(f"prose requirement has unknown status: {source}")

    for field in ("reason", "required_environment", "runner"):
      if not isinstance(classification[field], str) or not classification[field].strip():
        raise CatalogError(f"prose requirement has no {field}: {source}")

    if status == "passed":
      if activities[activity]["status"] != "completed":
        raise CatalogError(f"passing prose requirement has incomplete owner: {source}")

      if not isinstance(classification["last_execution"], str) or not classification["last_execution"]:
        raise CatalogError(f"passing prose requirement has no execution evidence: {source}")

      if classification["runner"].startswith("pending:"):
        raise CatalogError(f"passing prose requirement has a pending runner: {source}")
    else:
      if classification["last_execution"] is not None:
        raise CatalogError(f"non-passing prose requirement has execution evidence: {source}")

      if status == "deferred_unsupported" and activities[activity]["status"] == "completed":
        raise CatalogError(f"deferred prose requirement has completed owner: {source}")

    document = documents[source]
    identity = f"{source}::document"
    requirements[identity] = {
      **classification,
      "fingerprint": document["fingerprint"],
      "format": "prose",
      "scope": activities[activity]["scope"],
      "source": source,
      "specifications_commit": specifications_commit,
      "suite": document["suite"],
    }

  return requirements


def generate(
  source: Path = SOURCE,
  layers_path: Path = LAYERS,
) -> dict[str, Any]:
  documents = discover_accepted_documents(source)
  layers = _load_layers(layers_path)
  discovered_suites = {document["suite"] for document in documents.values()}
  mapped_suites = set(layers)

  if discovered_suites != mapped_suites:
    missing = sorted(discovered_suites - mapped_suites)
    stale = sorted(mapped_suites - discovered_suites)
    raise CatalogError(
      f"accepted specifications differ from onion manifest; "
      f"unmapped={missing}, stale={stale}"
    )

  suites = {}

  for suite in sorted(discovered_suites):
    suites[suite] = {
      "documents": [
        identity for identity, document in documents.items()
        if document["suite"] == suite
      ],
      "has_machine_fixtures": _has_machine_fixtures(source, suite),
      "layer": layers[suite],
    }

  specifications_commit = _specifications_commit()
  requirements = _generate_requirements(documents, suites, specifications_commit)
  requirement_statuses = {
    status: sum(value["status"] == status for value in requirements.values())
    for status in sorted(VALID_REQUIREMENT_STATUSES)
    if any(value["status"] == status for value in requirements.values())
  }

  return {
    "documents": documents,
    "requirements": requirements,
    "schema_version": 1,
    "specifications_commit": specifications_commit,
    "suites": suites,
    "summary": {
      "documents": len(documents),
      "machine_fixture_suites": sum(
        value["has_machine_fixtures"] for value in suites.values()
      ),
      "prose_only_suites": sum(
        not value["has_machine_fixtures"] for value in suites.values()
      ),
      "requirements": len(requirements),
      "requirement_statuses": requirement_statuses,
      "suites": len(suites),
    },
  }


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--check", action="store_true")
  arguments = parser.parse_args(argv)

  try:
    generated = generate()
    encoded = json.dumps(generated, indent=2, sort_keys=True) + "\n"
  except (CatalogError, OSError, UnicodeDecodeError) as exc:
    print(f"conformance catalog: {exc}", file=sys.stderr)
    return 2

  if arguments.check:
    if not OUTPUT.exists() or OUTPUT.read_text(encoding="utf-8") != encoded:
      print("conformance catalog is stale", file=sys.stderr)
      return 1
  else:
    OUTPUT.write_text(encoded, encoding="utf-8")

  summary = generated["summary"]
  print(
    f"conformance catalog: {summary['documents']} accepted documents, "
    f"{summary['suites']} suites, {summary['prose_only_suites']} prose-only"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
