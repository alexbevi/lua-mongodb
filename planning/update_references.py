#!/usr/bin/env python3
"""Advance one pinned reference and rebuild its dependent artifacts."""

from __future__ import annotations

import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Iterable, Sequence


PLANNING_DIR = Path(__file__).resolve().parent
ROOT = PLANNING_DIR.parent
REFERENCES_PATH = PLANNING_DIR / "references.json"
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
    ["fetch", "--no-tags", "--depth=1", "origin", commit],
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


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("reference", help="reference name from planning/references.json")
  parser.add_argument("commit", help="new full commit SHA")
  parser.add_argument(
    "--allow-non-fast-forward",
    action="store_true",
    help="allow a pin that does not descend from the current commit",
  )
  return parser


def main(argv: list[str] | None = None) -> int:
  arguments = build_parser().parse_args(argv)
  try:
    summary = advance_reference(
      arguments.reference,
      arguments.commit,
      allow_non_fast_forward=arguments.allow_non_fast_forward,
    )
  except ReferenceUpdateError as exc:
    print(f"reference update: {exc}", file=sys.stderr)
    return 1

  changes = ", ".join(f"{status}={count}" for status, count in summary.items()) or "none"
  print(f"updated {arguments.reference} to {arguments.commit}; upstream changes: {changes}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
