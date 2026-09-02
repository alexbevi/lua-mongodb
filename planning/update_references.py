#!/usr/bin/env python3
"""Advance one pinned reference and rebuild its dependent artifacts."""

from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Sequence


PLANNING_DIR = Path(__file__).resolve().parent
ROOT = PLANNING_DIR.parent
REFERENCES_PATH = PLANNING_DIR / "references.json"
PLAN_PATH = PLANNING_DIR / "plan.json"
PROGRESS_PATH = PLANNING_DIR / "progress.json"
UPDATE_PLAN_SPEC = importlib.util.spec_from_file_location(
  "planning_update_plan", PLANNING_DIR / "update_plan.py",
)
assert UPDATE_PLAN_SPEC and UPDATE_PLAN_SPEC.loader
update_plan = importlib.util.module_from_spec(UPDATE_PLAN_SPEC)
UPDATE_PLAN_SPEC.loader.exec_module(update_plan)

SPECIFICATION_GENERATORS: tuple[tuple[str, ...], ...] = (
  ("planning/update_spec_artifacts.py",),
)
REFERENCE_GENERATORS: tuple[tuple[str, ...], ...] = (
  ("planning/update_plan.py", "render-state"),
)


class ReferenceUpdateError(Exception):
  """A reference cannot be advanced safely."""


def run_git(
  directory: Path,
  arguments: Iterable[str],
) -> subprocess.CompletedProcess[str]:
  return subprocess.run(
    ["git", "-C", str(directory), *arguments],
    check=False,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
  )


def require_git(
  directory: Path,
  arguments: Iterable[str],
  description: str,
) -> str:
  result = run_git(directory, arguments)
  if result.returncode != 0:
    detail = result.stderr.strip() or result.stdout.strip()
    raise ReferenceUpdateError(f"{description}: {detail}")
  return result.stdout.strip()


def read_document(path: Path) -> dict:
  try:
    value = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ReferenceUpdateError(f"could not read {path}: {exc}") from exc
  if not isinstance(value, dict):
    raise ReferenceUpdateError(f"expected a JSON object in {path}")
  return value


def resolve_checkout(root: Path, relative: str) -> Path:
  checkout = (root / relative).resolve()
  try:
    checkout.relative_to(root.resolve())
  except ValueError as exc:
    raise ReferenceUpdateError(f"reference path escapes the repository: {relative}") from exc
  return checkout


def require_commit(checkout: Path, commit: str) -> None:
  available = run_git(checkout, ["cat-file", "-e", f"{commit}^{{commit}}"])
  if available.returncode == 0:
    return
  fetched = run_git(
    checkout,
    ["fetch", "--no-tags", "origin", commit],
  )
  if fetched.returncode != 0:
    detail = fetched.stderr.strip() or fetched.stdout.strip()
    raise ReferenceUpdateError(f"could not fetch pinned commit {commit}: {detail}")
  available = run_git(checkout, ["cat-file", "-e", f"{commit}^{{commit}}"])
  if available.returncode != 0:
    raise ReferenceUpdateError(f"fetched commit is unavailable: {commit}")


def validate_mappings(checkout: Path, reference: dict, commit: str) -> None:
  for mapping in reference.get("mappings", []):
    mapped_path = mapping["path"]
    present = run_git(checkout, ["cat-file", "-e", f"{commit}:{mapped_path}"])
    if present.returncode != 0:
      raise ReferenceUpdateError(f"missing mapped path {mapped_path} at {commit}")
    symbol = mapping.get("symbol")
    if symbol:
      source = require_git(
        checkout,
        ["show", f"{commit}:{mapped_path}"],
        f"could not read mapped path {mapped_path}",
      )
      if symbol not in update_plan.declared_symbols(source):
        raise ReferenceUpdateError(f"missing mapped symbol {symbol} in {mapped_path}")


def change_summary(checkout: Path, old: str, new: str) -> dict[str, int]:
  output = require_git(
    checkout,
    ["diff", "--name-status", old, new],
    "could not compare reference commits",
  )
  counts = Counter()
  for line in output.splitlines():
    if line:
      counts[line.split("\t", 1)[0][0]] += 1
  return dict(sorted(counts.items()))


def changed_paths(checkout: Path, old: str, new: str) -> list[dict[str, str]]:
  output = require_git(
    checkout,
    ["diff", "--name-status", "--no-renames", "-z", old, new, "--"],
    "could not compare reference paths",
  )
  fields = output.split("\0")
  if fields and fields[-1] == "":
    fields.pop()
  if len(fields) % 2 != 0:
    raise ReferenceUpdateError("could not parse changed reference paths")
  return [
    {"status": fields[index][0], "path": fields[index + 1]}
    for index in range(0, len(fields), 2)
  ]


def changed_commits(checkout: Path, old: str, new: str) -> list[str]:
  output = require_git(
    checkout,
    ["rev-list", "--reverse", "--topo-order", f"{old}..{new}"],
    "could not list reference commits",
  )
  return output.splitlines() if output else []


def object_id(checkout: Path, commit: str, path: str) -> str | None:
  result = run_git(checkout, ["rev-parse", f"{commit}:{path}"])
  return result.stdout.strip() if result.returncode == 0 else None


def roadmap_impacts(
  changed_mappings: set[str],
  plan_path: Path,
  progress_path: Path,
) -> list[dict[str, Any]]:
  if not changed_mappings or not plan_path.exists() or not progress_path.exists():
    return []
  try:
    plan = json.loads(plan_path.read_text(encoding="utf-8"))
    progress = json.loads(progress_path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ReferenceUpdateError(f"could not read roadmap impact inputs: {exc}") from exc

  records = progress.get("activities", {})
  impacts = []
  for activity in plan.get("activities", []):
    mappings = sorted(changed_mappings.intersection(activity.get("references", [])))
    if not mappings:
      continue
    activity_id = activity["id"]
    impacts.append({
      "id": activity_id,
      "mappings": mappings,
      "status": records.get(activity_id, {}).get("status", "pending"),
    })
  return sorted(impacts, key=lambda value: value["id"])


def inventory_delta(
  before: dict[str, dict[str, Any]],
  after: dict[str, dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
  before_ids = set(before)
  after_ids = set(after)
  return {
    "added": [
      {"identity": identity, **after[identity]}
      for identity in sorted(after_ids - before_ids)
    ],
    "removed": [
      {"identity": identity, **before[identity]}
      for identity in sorted(before_ids - after_ids)
    ],
    "changed": [
      {"identity": identity, "from": before[identity], "to": after[identity]}
      for identity in sorted(before_ids & after_ids)
      if before[identity] != after[identity]
    ],
  }


def discover_specification_inventory(source: Path) -> dict[str, dict[str, Any]]:
  if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
  from spec.conformance import catalog, ledger
  from spec.unified import run

  try:
    unified_tests = {
      value["id"]: {
        "fingerprint": value["fingerprint"],
        "fixture": value["fixture"],
        "requirements": value["requirements"],
      }
      for value in run.discover_tests(source)
    }
    return {
      "accepted_documents": catalog.discover_accepted_documents(source),
      "cases": ledger.discover_cases(source),
      "fixture_files": ledger.discover_files(source),
      "unified_tests": unified_tests,
    }
  except (OSError, UnicodeDecodeError, catalog.CatalogError,
          ledger.LedgerError, run.CapabilityError) as exc:
    raise ReferenceUpdateError(f"could not inventory specifications: {exc}") from exc


@contextmanager
def temporary_worktree(checkout: Path, commit: str) -> Iterable[Path]:
  with tempfile.TemporaryDirectory(prefix="lua-mongodb-reference-") as temporary:
    worktree = Path(temporary) / "checkout"
    require_git(
      checkout,
      ["worktree", "add", "--detach", str(worktree), commit],
      "could not materialize candidate reference",
    )
    try:
      yield worktree
    finally:
      require_git(
        checkout,
        ["worktree", "remove", "--force", str(worktree)],
        "could not remove candidate reference worktree",
      )


def specification_inventory_delta(
  checkout: Path,
  old: str,
  new: str,
) -> dict[str, dict[str, list[dict[str, Any]]]]:
  before = discover_specification_inventory(checkout / "source")
  with temporary_worktree(checkout, new) as candidate:
    after = discover_specification_inventory(candidate / "source")
  return {
    name: inventory_delta(before[name], after[name])
    for name in sorted(before)
  }


def analyze_reference(
  name: str,
  commit: str,
  *,
  root: Path = ROOT,
  references_path: Path = REFERENCES_PATH,
  plan_path: Path = PLAN_PATH,
  progress_path: Path = PROGRESS_PATH,
  allow_non_fast_forward: bool = False,
) -> dict[str, Any]:
  """Report the Git, mapping, and roadmap impact without moving a pin."""
  if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise ReferenceUpdateError("new commit must be a full lowercase 40-character SHA")

  document = read_document(references_path)
  references = document.get("references", {})
  if name not in references:
    raise ReferenceUpdateError(f"unknown reference: {name}")
  reference = references[name]
  checkout = resolve_checkout(root, reference["path"])
  if not checkout.exists():
    raise ReferenceUpdateError(f"missing reference checkout: {reference['path']}")

  dirty = require_git(checkout, ["status", "--porcelain"], "could not inspect checkout")
  if dirty:
    raise ReferenceUpdateError(f"reference checkout is dirty: {reference['path']}")

  old = reference["commit"]
  actual = require_git(checkout, ["rev-parse", "HEAD"], "could not read checkout HEAD")
  if actual != old:
    raise ReferenceUpdateError(f"reference HEAD is {actual}, expected {old}")

  require_commit(checkout, commit)
  ancestry = run_git(checkout, ["merge-base", "--is-ancestor", old, commit])
  if ancestry.returncode != 0 and not allow_non_fast_forward:
    raise ReferenceUpdateError(
      f"new {name} commit is not a descendant of the current pin; "
      "pass --allow-non-fast-forward to override",
    )

  validate_mappings(checkout, reference, commit)
  paths = changed_paths(checkout, old, commit)
  landmarks = []
  changed_mapping_ids = set()
  for mapping in reference.get("mappings", []):
    mapping_id = f"{name}:{mapping['name']}"
    changed = object_id(checkout, old, mapping["path"]) != object_id(
      checkout, commit, mapping["path"],
    )
    if changed:
      changed_mapping_ids.add(mapping_id)
    landmarks.append({
      "changed": changed,
      "id": mapping_id,
      "path": mapping["path"],
      "symbol": mapping.get("symbol"),
    })

  impacts = roadmap_impacts(changed_mapping_ids, plan_path, progress_path)
  report = {
    "affected_activities": impacts,
    "changed_paths": paths,
    "commits": changed_commits(checkout, old, commit),
    "from_commit": old,
    "mapped_landmarks": landmarks,
    "reference": name,
    "review_candidates": [
      impact["id"] for impact in impacts
      if impact["status"] in {"completed", "in_progress", "needs_review"}
    ],
    "schema_version": 1,
    "to_commit": commit,
    "valid": True,
  }
  project_head = run_git(root, ["rev-parse", "HEAD"])
  if project_head.returncode == 0:
    report["project_commit"] = project_head.stdout.strip()
  if name == "specifications":
    report["specification_inventory"] = specification_inventory_delta(
      checkout, old, commit,
    )
  return report


def render_impact(report: dict[str, Any], output_format: str) -> str:
  if output_format == "json":
    return json.dumps(report, indent=2, sort_keys=True)
  if not report.get("valid") and report.get("errors"):
    return f"dry run failed: {'; '.join(report.get('errors', []))}"
  changed = Counter(value["status"] for value in report["changed_paths"])
  summary = ", ".join(
    f"{status}={count}" for status, count in sorted(changed.items())
  ) or "none"
  lines = [
    f"dry run: {report['reference']} {report['from_commit']} -> {report['to_commit']}",
    f"upstream commits: {len(report['commits'])}",
    f"changed paths: {summary}",
    f"changed mappings: {sum(value['changed'] for value in report['mapped_landmarks'])}",
    f"affected activities: {len(report['affected_activities'])}",
    f"review candidates: {len(report['review_candidates'])}",
  ]
  if "specification_inventory" in report:
    inventory = report["specification_inventory"]
    for name in ("accepted_documents", "fixture_files", "cases", "unified_tests"):
      delta = inventory[name]
      lines.append(
        f"{name.replace('_', ' ')}: "
        f"added={len(delta['added'])}, removed={len(delta['removed'])}, "
        f"changed={len(delta['changed'])}"
      )
  simulation = report.get("simulation")
  if simulation:
    lines.extend((
      f"generator simulation: {'passed' if simulation['valid'] else 'failed'}",
      f"generated files: {len(simulation['generated_files'])}",
      f"repeatable: {'yes' if simulation['repeatable'] else 'no'}",
    ))
  if report.get("impact_digest"):
    lines.append(f"impact digest: {report['impact_digest']}")
  return "\n".join(lines)


def impact_digest(report: dict[str, Any]) -> str:
  payload = {key: value for key, value in report.items() if key != "impact_digest"}
  encoded = json.dumps(
    payload,
    ensure_ascii=False,
    separators=(",", ":"),
    sort_keys=True,
  ).encode("utf-8")
  return hashlib.sha256(encoded).hexdigest()


def require_expected_impact(report: dict[str, Any], expected: str) -> None:
  if not re.fullmatch(r"[0-9a-f]{64}", expected):
    raise ReferenceUpdateError("reviewed impact digest must be 64 lowercase hex characters")
  simulation = report.get("simulation")
  if not report.get("valid") and (
    not simulation or not simulation.get("repeatable")
  ):
    raise ReferenceUpdateError("reviewed impact is not repeatable")
  actual = impact_digest(report)
  if actual != expected:
    raise ReferenceUpdateError(
      f"reviewed impact digest is {actual}, expected {expected}",
    )


def submodule_name(root: Path, relative: str) -> str:
  output = require_git(
    root,
    ["config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
    "could not inspect submodule declarations",
  )
  for line in output.splitlines():
    key, value = line.split(None, 1)
    if value == relative:
      return key.removeprefix("submodule.").removesuffix(".path")
  raise ReferenceUpdateError(f"reference path is not a declared submodule: {relative}")


@contextmanager
def temporary_project_clone(
  root: Path,
  reference: dict[str, Any],
) -> Iterable[Path]:
  base_commit = require_git(root, ["rev-parse", "HEAD"], "could not read project HEAD")
  with tempfile.TemporaryDirectory(prefix="lua-mongodb-project-") as temporary:
    sandbox = Path(temporary) / "project"
    cloned = subprocess.run(
      ["git", "clone", "--shared", "--no-checkout", "--quiet", str(root), str(sandbox)],
      check=False,
      text=True,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
    )
    if cloned.returncode != 0:
      detail = cloned.stderr.strip() or cloned.stdout.strip()
      raise ReferenceUpdateError(f"could not create project sandbox: {detail}")
    require_git(
      sandbox,
      ["checkout", "--detach", "--quiet", base_commit],
      "could not check out project sandbox",
    )

    relative = reference["path"]
    name = submodule_name(sandbox, relative)
    local_checkout = resolve_checkout(root, relative)
    require_git(
      sandbox,
      ["config", f"submodule.{name}.url", str(local_checkout)],
      "could not configure sandbox reference source",
    )
    require_git(
      sandbox,
      [
        "-c", "protocol.file.allow=always", "submodule", "update", "--init", "--",
        relative,
      ],
      "could not initialize sandbox reference",
    )
    yield sandbox


def file_content_id(path: Path) -> str | None:
  if path.is_file():
    return hashlib.sha256(path.read_bytes()).hexdigest()
  if path.is_dir():
    result = run_git(path, ["rev-parse", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else None
  return None


def project_changes(root: Path) -> list[dict[str, Any]]:
  output = require_git(
    root,
    ["diff", "--name-status", "--no-renames", "-z", "HEAD", "--"],
    "could not inspect simulated project changes",
  )
  fields = output.split("\0")
  if fields and fields[-1] == "":
    fields.pop()
  if len(fields) % 2 != 0:
    raise ReferenceUpdateError("could not parse simulated project changes")
  statuses = {
    fields[index + 1]: fields[index][0]
    for index in range(0, len(fields), 2)
  }
  untracked = require_git(
    root,
    ["ls-files", "--others", "--exclude-standard", "-z"],
    "could not inspect simulated untracked files",
  )
  for path in filter(None, untracked.split("\0")):
    statuses[path] = "A"
  return [
    {
      "content_id": file_content_id(root / path),
      "path": path,
      "status": statuses[path],
    }
    for path in sorted(statuses)
  ]


def execute_generators(
  root: Path,
  commands: Sequence[Sequence[str]],
) -> list[dict[str, Any]]:
  results = []
  for command in commands:
    result = subprocess.run(
      [sys.executable, *command],
      cwd=root,
      check=False,
      text=True,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
    )
    entry: dict[str, Any] = {
      "command": " ".join(command),
      "exit_code": result.returncode,
    }
    if result.returncode != 0:
      detail = (result.stderr.strip() or result.stdout.strip()).replace(str(root), ".")
      entry["error"] = detail
    results.append(entry)
    if result.returncode != 0:
      break
  return results


def simulate_reference_update(
  name: str,
  commit: str,
  *,
  root: Path = ROOT,
  references_path: Path = REFERENCES_PATH,
  allow_non_fast_forward: bool = False,
  generator_commands: Sequence[Sequence[str]] | None = None,
) -> dict[str, Any]:
  clean = require_git(
    root,
    ["status", "--porcelain=v1", "--untracked-files=all"],
    "could not inspect project checkout",
  )
  if clean:
    raise ReferenceUpdateError("dry-run generator simulation requires a clean project checkout")

  document = read_document(references_path)
  references = document.get("references", {})
  if name not in references:
    raise ReferenceUpdateError(f"unknown reference: {name}")
  reference = references[name]
  relative_references = references_path.resolve().relative_to(root.resolve())
  commands = generator_commands
  if commands is None:
    commands = SPECIFICATION_GENERATORS if name == "specifications" else REFERENCE_GENERATORS

  with temporary_project_clone(root, reference) as sandbox:
    sandbox_references = sandbox / relative_references
    if commit != reference["commit"]:
      advance_reference(
        name,
        commit,
        root=sandbox,
        references_path=sandbox_references,
        allow_non_fast_forward=allow_non_fast_forward,
        generator_commands=(),
      )

    first_results = execute_generators(sandbox, commands)
    first_changes = project_changes(sandbox)
    first_passed = all(result["exit_code"] == 0 for result in first_results)
    second_results = execute_generators(sandbox, commands)
    second_changes = project_changes(sandbox)
    second_passed = all(result["exit_code"] == 0 for result in second_results)
    repeatable = first_results == second_results and first_changes == second_changes
    excluded = {relative_references.as_posix(), reference["path"]}
    generated = [
      change for change in first_changes
      if change["path"] not in excluded
    ]
    return {
      "first_run": first_results,
      "generated_files": generated,
      "repeatable": repeatable,
      "second_run": second_results,
      "valid": first_passed and second_passed and repeatable,
    }


def build_impact_report(
  name: str,
  commit: str,
  *,
  root: Path = ROOT,
  references_path: Path = REFERENCES_PATH,
  plan_path: Path = PLAN_PATH,
  progress_path: Path = PROGRESS_PATH,
  allow_non_fast_forward: bool = False,
  generator_commands: Sequence[Sequence[str]] | None = None,
) -> dict[str, Any]:
  report = analyze_reference(
    name,
    commit,
    root=root,
    references_path=references_path,
    plan_path=plan_path,
    progress_path=progress_path,
    allow_non_fast_forward=allow_non_fast_forward,
  )
  report["simulation"] = simulate_reference_update(
    name,
    commit,
    root=root,
    references_path=references_path,
    allow_non_fast_forward=allow_non_fast_forward,
    generator_commands=generator_commands,
  )
  report["valid"] = report["valid"] and report["simulation"]["valid"]
  report["impact_digest"] = impact_digest(report)
  return report


def run_generators(root: Path, commands: Sequence[Sequence[str]]) -> None:
  for command in commands:
    result = subprocess.run(
      [sys.executable, *command],
      cwd=root,
      check=False,
      text=True,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
      detail = result.stderr.strip() or result.stdout.strip()
      rendered = " ".join(command)
      raise ReferenceUpdateError(f"artifact regeneration failed at {rendered}: {detail}")


def advance_reference(
  name: str,
  commit: str,
  *,
  root: Path = ROOT,
  references_path: Path = REFERENCES_PATH,
  allow_non_fast_forward: bool = False,
  generator_commands: Sequence[Sequence[str]] | None = None,
) -> dict[str, int]:
  if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise ReferenceUpdateError("new commit must be a full lowercase 40-character SHA")

  document = read_document(references_path)
  references = document.get("references", {})
  if name not in references:
    raise ReferenceUpdateError(f"unknown reference: {name}")
  reference = references[name]
  checkout = resolve_checkout(root, reference["path"])
  if not checkout.exists():
    raise ReferenceUpdateError(f"missing reference checkout: {reference['path']}")

  dirty = require_git(checkout, ["status", "--porcelain"], "could not inspect checkout")
  if dirty:
    raise ReferenceUpdateError(f"reference checkout is dirty: {reference['path']}")

  old = reference["commit"]
  actual = require_git(checkout, ["rev-parse", "HEAD"], "could not read checkout HEAD")
  if actual != old:
    raise ReferenceUpdateError(f"reference HEAD is {actual}, expected {old}")
  if commit == old:
    raise ReferenceUpdateError(f"reference {name} is already pinned to {commit}")

  require_commit(checkout, commit)
  ancestry = run_git(checkout, ["merge-base", "--is-ancestor", old, commit])
  if ancestry.returncode != 0 and not allow_non_fast_forward:
    raise ReferenceUpdateError(
      f"new {name} commit is not a descendant of the current pin; "
      "pass --allow-non-fast-forward to override",
    )

  validate_mappings(checkout, reference, commit)
  summary = change_summary(checkout, old, commit)
  require_git(checkout, ["checkout", "--detach", commit], "could not update checkout")
  reference["commit"] = commit
  update_plan.atomic_write(references_path, document)

  commands = generator_commands
  if commands is None:
    commands = SPECIFICATION_GENERATORS if name == "specifications" else REFERENCE_GENERATORS
  run_generators(root, commands)
  return summary


def advance_reviewed_reference(
  name: str,
  commit: str,
  expected_impact: str,
  *,
  root: Path = ROOT,
  references_path: Path = REFERENCES_PATH,
  plan_path: Path = PLAN_PATH,
  progress_path: Path = PROGRESS_PATH,
  allow_non_fast_forward: bool = False,
  generator_commands: Sequence[Sequence[str]] | None = None,
) -> dict[str, Any]:
  report = build_impact_report(
    name,
    commit,
    root=root,
    references_path=references_path,
    plan_path=plan_path,
    progress_path=progress_path,
    allow_non_fast_forward=allow_non_fast_forward,
    generator_commands=generator_commands,
  )
  require_expected_impact(report, expected_impact)
  artifacts_regenerated = report["simulation"]["valid"]
  commands: Sequence[Sequence[str]] = ()
  if artifacts_regenerated:
    commands = generator_commands if generator_commands is not None else (
      SPECIFICATION_GENERATORS if name == "specifications" else REFERENCE_GENERATORS
    )
  summary = advance_reference(
    name,
    commit,
    root=root,
    references_path=references_path,
    allow_non_fast_forward=allow_non_fast_forward,
    generator_commands=commands,
  )
  return {
    "artifacts_regenerated": artifacts_regenerated,
    "summary": summary,
  }


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("reference", help="reference name from planning/references.json")
  parser.add_argument("commit", help="new full commit SHA")
  parser.add_argument(
    "--allow-non-fast-forward",
    action="store_true",
    help="allow a pin that does not descend from the current commit",
  )
  parser.add_argument(
    "--dry-run",
    action="store_true",
    help="report candidate impact without moving the pin",
  )
  parser.add_argument(
    "--format",
    choices=("text", "json"),
    default="text",
    help="dry-run output format",
  )
  parser.add_argument(
    "--expect-impact",
    help="apply only when a fresh dry run has this impact digest",
  )
  return parser


def main(argv: list[str] | None = None) -> int:
  arguments = build_parser().parse_args(argv)
  artifacts_regenerated = True
  try:
    if arguments.dry_run and arguments.expect_impact:
      raise ReferenceUpdateError("--expect-impact cannot be combined with --dry-run")
    if arguments.dry_run:
      report = build_impact_report(
        arguments.reference,
        arguments.commit,
        allow_non_fast_forward=arguments.allow_non_fast_forward,
      )
      print(render_impact(report, arguments.format))
      return 0 if report["valid"] else 1
    if arguments.format != "text":
      raise ReferenceUpdateError("--format requires --dry-run")
    if arguments.expect_impact:
      reviewed = advance_reviewed_reference(
        arguments.reference,
        arguments.commit,
        arguments.expect_impact,
        allow_non_fast_forward=arguments.allow_non_fast_forward,
      )
      summary = reviewed["summary"]
      artifacts_regenerated = reviewed["artifacts_regenerated"]
    else:
      summary = advance_reference(
        arguments.reference,
        arguments.commit,
        allow_non_fast_forward=arguments.allow_non_fast_forward,
      )
  except ReferenceUpdateError as exc:
    if arguments.dry_run:
      report = {
        "errors": [str(exc)],
        "reference": arguments.reference,
        "schema_version": 1,
        "to_commit": arguments.commit,
        "valid": False,
      }
      report["impact_digest"] = impact_digest(report)
      output = render_impact(report, arguments.format)
      print(output, file=sys.stdout if arguments.format == "json" else sys.stderr)
      return 1
    print(f"reference update: {exc}", file=sys.stderr)
    return 1

  changes = ", ".join(f"{status}={count}" for status, count in summary.items()) or "none"
  print(f"updated {arguments.reference} to {arguments.commit}; upstream changes: {changes}")
  if not artifacts_regenerated:
    print(
      "reviewed generator failures remain; update classifications and run "
      "make update-spec-artifacts",
    )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
