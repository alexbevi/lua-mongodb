#!/usr/bin/env python3
"""Validate and update the Lua MongoDB driver's executable roadmap.

This module intentionally uses only the Python standard library so the
planning bootstrap can validate itself before the Lua toolchain exists.
"""

from __future__ import annotations

import argparse
import ast
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Iterable


PLANNING_DIR = Path(__file__).resolve().parent
ROOT = PLANNING_DIR.parent
PLAN_PATH = PLANNING_DIR / "plan.json"
PROGRESS_PATH = PLANNING_DIR / "progress.json"
STATE_PATH = PLANNING_DIR / "current_state.json"
STATUSES = {"pending", "in_progress", "blocked", "completed", "needs_review"}
COMMIT_RE = re.compile(r"^[a-z]+\([a-z0-9-]+\)!?: .+")


class PlanError(Exception):
  """A user-facing roadmap validation or transition error."""


def utc_now() -> str:
  return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()


def read_json(path: Path) -> dict[str, Any]:
  try:
    with path.open("r", encoding="utf-8") as handle:
      value = json.load(handle)
  except FileNotFoundError as exc:
    raise PlanError(f"missing JSON file: {path}") from exc
  except json.JSONDecodeError as exc:
    raise PlanError(f"malformed JSON in {path}: {exc}") from exc
  if not isinstance(value, dict):
    raise PlanError(f"expected JSON object in {path}")
  return value


def atomic_write(path: Path, value: dict[str, Any]) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
  try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
      json.dump(value, handle, indent=2, sort_keys=False)
      handle.write("\n")
      handle.flush()
      os.fsync(handle.fileno())
    os.replace(temporary, path)
  finally:
    if os.path.exists(temporary):
      os.unlink(temporary)


def digest_plan(plan: dict[str, Any]) -> str:
  canonical = json.dumps(plan, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
  return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def activity_map(plan: dict[str, Any]) -> dict[str, dict[str, Any]]:
  activities = plan.get("activities")
  if not isinstance(activities, list):
    raise PlanError("plan.activities must be an array")
  result: dict[str, dict[str, Any]] = {}
  for activity in activities:
    if not isinstance(activity, dict) or not isinstance(activity.get("id"), str):
      raise PlanError("every activity must be an object with a string id")
    activity_id = activity["id"]
    if activity_id in result:
      raise PlanError(f"duplicate activity id: {activity_id}")
    result[activity_id] = activity
  return result


def validate_plan(plan: dict[str, Any]) -> list[str]:
  issues: list[str] = []
  if plan.get("schema_version") != 1:
    issues.append("plan.schema_version must be 1")
  if not isinstance(plan.get("plan_id"), str) or not plan.get("plan_id"):
    issues.append("plan.plan_id must be a non-empty string")
  try:
    activities = activity_map(plan)
  except PlanError as exc:
    return [str(exc)]

  milestone_ids = {
    item.get("id") for item in plan.get("milestones", []) if isinstance(item, dict)
  }
  mapping_ids: set[str] = set()
  references = plan.get("references")
  if not isinstance(references, dict) or not references:
    issues.append("plan.references must be a non-empty object")
    references = {}
  for reference_name, reference in references.items():
    if not isinstance(reference, dict):
      issues.append(f"reference {reference_name} must be an object")
      continue
    if not re.fullmatch(r"[0-9a-f]{40}", str(reference.get("commit", ""))):
      issues.append(f"reference {reference_name} commit must be a 40-character SHA")
    if not reference.get("path") or not reference.get("url"):
      issues.append(f"reference {reference_name} requires path and url")
    for mapping in reference.get("mappings", []):
      if not isinstance(mapping, dict) or not mapping.get("name") or not mapping.get("path"):
        issues.append(f"reference {reference_name} has an invalid mapping")
      else:
        mapping_id = f"{reference_name}:{mapping['name']}"
        if mapping_id in mapping_ids:
          issues.append(f"duplicate reference mapping: {mapping_id}")
        mapping_ids.add(mapping_id)

  for activity_id, activity in activities.items():
    required = (
      "title", "milestone", "depends_on", "references", "test_policy",
      "test_first", "implementation", "verification", "acceptance", "docs", "commit",
    )
    for key in required:
      if key not in activity:
        issues.append(f"activity {activity_id} is missing {key}")
    if activity.get("milestone") not in milestone_ids:
      issues.append(f"activity {activity_id} has unknown milestone {activity.get('milestone')}")
    dependencies = activity.get("depends_on", [])
    if not isinstance(dependencies, list):
      issues.append(f"activity {activity_id}.depends_on must be an array")
      dependencies = []
    for dependency in dependencies:
      if dependency not in activities:
        issues.append(f"activity {activity_id} has unknown dependency {dependency}")
      if dependency == activity_id:
        issues.append(f"activity {activity_id} depends on itself")
    if len(dependencies) != len(set(dependencies)):
      issues.append(f"activity {activity_id} has duplicate dependencies")
    if activity.get("test_policy") not in {"red_green", "validation"}:
      issues.append(f"activity {activity_id} has invalid test_policy")
    if not COMMIT_RE.fullmatch(str(activity.get("commit", ""))):
      issues.append(f"activity {activity_id} has invalid Conventional Commit subject")
    for mapping_id in activity.get("references", []):
      if mapping_id not in mapping_ids:
        issues.append(f"activity {activity_id} has unknown reference {mapping_id}")

  visiting: set[str] = set()
  visited: set[str] = set()

  def visit(activity_id: str, chain: list[str]) -> None:
    if activity_id in visited:
      return
    if activity_id in visiting:
      cycle = " -> ".join(chain + [activity_id])
      issues.append(f"dependency cycle: {cycle}")
      return
    visiting.add(activity_id)
    for dependency in activities[activity_id].get("depends_on", []):
      if dependency in activities:
        visit(dependency, chain + [activity_id])
    visiting.remove(activity_id)
    visited.add(activity_id)

  for activity_id in activities:
    visit(activity_id, [])
  return issues


def validate_progress(plan: dict[str, Any], progress: dict[str, Any]) -> list[str]:
  issues: list[str] = []
  activities = activity_map(plan)
  if progress.get("schema_version") != 1:
    issues.append("progress.schema_version must be 1")
  if progress.get("plan_id") != plan.get("plan_id"):
    issues.append("progress.plan_id does not match plan")
  records = progress.get("activities")
  if not isinstance(records, dict):
    return issues + ["progress.activities must be an object"]
  active = 0
  for activity_id, record in records.items():
    if activity_id not in activities:
      issues.append(f"progress has unknown activity {activity_id}")
      continue
    if not isinstance(record, dict):
      issues.append(f"progress activity {activity_id} must be an object")
      continue
    status = record.get("status")
    if status not in STATUSES:
      issues.append(f"progress activity {activity_id} has invalid status {status}")
    if status == "in_progress":
      active += 1
    if not isinstance(record.get("evidence", []), list):
      issues.append(f"progress activity {activity_id}.evidence must be an array")
    if not isinstance(record.get("notes", []), list):
      issues.append(f"progress activity {activity_id}.notes must be an array")
  if active > 1:
    issues.append("only one activity may be in_progress")
  return issues


def run_git(path: Path, arguments: Iterable[str]) -> subprocess.CompletedProcess[str]:
  return subprocess.run(
    ["git", "-C", str(path), *arguments],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
  )


def declared_symbols(source: str) -> set[str]:
  try:
    tree = ast.parse(source)
  except SyntaxError:
    return set()
  return {
    node.name for node in ast.walk(tree)
    if isinstance(node, (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef))
  }


def inspect_references(plan: dict[str, Any], root: Path = ROOT) -> dict[str, dict[str, Any]]:
  report: dict[str, dict[str, Any]] = {}
  for name, reference in plan.get("references", {}).items():
    relative = Path(reference["path"])
    checkout = root / relative
    expected = reference["commit"]
    issues: list[str] = []
    actual: str | None = None
    if not checkout.exists():
      issues.append(f"missing checkout {relative}")
    else:
      head = run_git(checkout, ["rev-parse", "HEAD"])
      if head.returncode != 0:
        issues.append(f"{relative} is not a Git checkout")
      else:
        actual = head.stdout.strip()
        if actual != expected:
          issues.append(f"HEAD is {actual}, expected {expected}")
        pinned = run_git(checkout, ["cat-file", "-e", f"{expected}^{{commit}}"])
        if pinned.returncode != 0:
          issues.append(f"pinned commit {expected} is unavailable")
        for mapping in reference.get("mappings", []):
          mapped_path = mapping["path"]
          tree_entry = run_git(checkout, ["cat-file", "-e", f"{expected}:{mapped_path}"])
          if tree_entry.returncode != 0:
            issues.append(f"missing mapped path {mapped_path} at pinned commit")
            continue
          symbol = mapping.get("symbol")
          if symbol:
            content = run_git(checkout, ["show", f"{expected}:{mapped_path}"])
            if content.returncode != 0 or symbol not in declared_symbols(content.stdout):
              issues.append(f"missing mapped symbol {symbol} in {mapped_path}")
    report[name] = {
      "path": str(relative),
      "expected": expected,
      "actual": actual,
      "status": "ok" if not issues else "stale",
      "issues": issues,
    }
  return report


def status_for(progress: dict[str, Any], activity_id: str) -> str:
  return progress.get("activities", {}).get(activity_id, {}).get("status", "pending")


def compute_state(
  plan: dict[str, Any], progress: dict[str, Any],
  reference_report: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
  activities = activity_map(plan)
  report = reference_report if reference_report is not None else inspect_references(plan)
  counts = {status: 0 for status in sorted(STATUSES)}
  active: list[str] = []
  blocked: list[str] = []
  needs_review: list[str] = []
  ready: list[str] = []
  for activity_id, activity in activities.items():
    status = status_for(progress, activity_id)
    counts[status] = counts.get(status, 0) + 1
    if status == "in_progress":
      active.append(activity_id)
    elif status == "blocked":
      blocked.append(activity_id)
    elif status == "needs_review":
      needs_review.append(activity_id)
    if status == "pending" and all(
      status_for(progress, dependency) == "completed"
      for dependency in activity.get("depends_on", [])
    ):
      ready.append(activity_id)
  stale: list[str] = []
  actual_digest = digest_plan(plan)
  if progress.get("plan_digest") != actual_digest:
    stale.append("progress plan_digest does not match plan.json")
  for name, details in report.items():
    stale.extend(f"{name}: {issue}" for issue in details["issues"])
  public_references = {
    name: {
      "expected": details["expected"],
      "actual": details["actual"],
      "status": details["status"],
    }
    for name, details in report.items()
  }
  return {
    "$schema": "./schemas/current_state.schema.json",
    "schema_version": 1,
    "plan_id": plan["plan_id"],
    "plan_digest": actual_digest,
    "references": public_references,
    "counts": counts,
    "active": active,
    "ready": ready,
    "blocked": blocked,
    "needs_review": needs_review,
    "stale": stale,
    "next_ready": ready[0] if ready else None,
  }


def git_commit_issues(plan: dict[str, Any], progress: dict[str, Any], root: Path = ROOT) -> list[str]:
  probe = run_git(root, ["rev-parse", "--show-toplevel"])
  if probe.returncode != 0:
    return ["strict commit validation requires a Git repository"]
  log = run_git(root, ["log", "--format=%H%x1f%s%x1f%B%x1e", "--all"])
  if log.returncode != 0:
    return [f"could not inspect Git history: {log.stderr.strip()}"]
  commits: list[tuple[str, str, str]] = []
  for record in log.stdout.split("\x1e"):
    fields = record.strip().split("\x1f", 2)
    if len(fields) == 3:
      commits.append((fields[0], fields[1], fields[2]))
  issues: list[str] = []
  for activity in plan["activities"]:
    activity_id = activity["id"]
    if status_for(progress, activity_id) != "completed":
      continue
    trailer = f"Plan-Activity: {activity_id}"
    matching = [item for item in commits if trailer in item[2].splitlines()]
    if not matching:
      issues.append(f"completed activity {activity_id} has no commit trailer")
    elif not any(item[1] == activity["commit"] for item in matching):
      issues.append(f"completed activity {activity_id} has no exact commit subject")
  return issues


def load_documents() -> tuple[dict[str, Any], dict[str, Any]]:
  return read_json(PLAN_PATH), read_json(PROGRESS_PATH)


def assert_valid_core(plan: dict[str, Any], progress: dict[str, Any]) -> None:
  issues = validate_plan(plan) + validate_progress(plan, progress)
  if issues:
    raise PlanError("\n".join(issues))


def save_progress_and_state(plan: dict[str, Any], progress: dict[str, Any]) -> None:
  report = inspect_references(plan)
  atomic_write(PROGRESS_PATH, progress)
  atomic_write(STATE_PATH, compute_state(plan, progress, report))


def command_refresh(_: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  progress["plan_digest"] = digest_plan(plan)
  report = inspect_references(plan)
  progress["verified_references"] = {
    name: {"commit": details["actual"], "status": details["status"]}
    for name, details in report.items()
  }
  atomic_write(PROGRESS_PATH, progress)
  atomic_write(STATE_PATH, compute_state(plan, progress, report))
  print("refreshed planning/current_state.json")
  return 0


def command_check(arguments: argparse.Namespace) -> int:
  try:
    plan, progress = load_documents()
    issues = validate_plan(plan) + validate_progress(plan, progress)
    report = inspect_references(plan)
    state = compute_state(plan, progress, report)
    issues.extend(state["stale"])
    try:
      existing_state = read_json(STATE_PATH)
      if existing_state != state:
        issues.append("planning/current_state.json is not the deterministic generated state; run refresh")
    except PlanError as exc:
      issues.append(str(exc))
    if arguments.strict:
      issues.extend(git_commit_issues(plan, progress))
    if issues:
      for issue in dict.fromkeys(issues):
        print(f"ERROR: {issue}", file=sys.stderr)
      return 1
    print("plan, progress, generated state, and references are valid")
    return 0
  except PlanError as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    return 1


def command_next(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  state = compute_state(plan, progress)
  if state["stale"]:
    raise PlanError("state is stale; run check and resolve reference or digest issues")
  activity_id = state["next_ready"]
  if activity_id is None:
    if arguments.json:
      print("null")
    else:
      print("no ready activity")
    return 0
  activity = activity_map(plan)[activity_id]
  if arguments.json:
    print(json.dumps(activity, indent=2))
  else:
    print(f"{activity_id}: {activity['title']}")
  return 0


def require_activity(plan: dict[str, Any], activity_id: str) -> dict[str, Any]:
  activities = activity_map(plan)
  if activity_id not in activities:
    raise PlanError(f"unknown activity: {activity_id}")
  return activities[activity_id]


def ensure_record(progress: dict[str, Any], activity_id: str) -> dict[str, Any]:
  return progress.setdefault("activities", {}).setdefault(
    activity_id, {"status": "pending", "evidence": [], "notes": []},
  )


def command_start(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  activity = require_activity(plan, arguments.activity_id)
  if any(status_for(progress, item["id"]) == "in_progress" for item in plan["activities"]):
    raise PlanError("another activity is already in_progress")
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] not in {"pending", "needs_review"}:
    raise PlanError(f"cannot start {arguments.activity_id} from {record['status']}")
  incomplete = [
    dependency for dependency in activity["depends_on"]
    if status_for(progress, dependency) != "completed"
  ]
  if incomplete:
    raise PlanError(f"dependencies are not completed: {', '.join(incomplete)}")
  record["status"] = "in_progress"
  record["started_at"] = utc_now()
  save_progress_and_state(plan, progress)
  print(f"started {arguments.activity_id}")
  return 0


def command_requeue(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  require_activity(plan, arguments.activity_id)
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] != "in_progress":
    raise PlanError(f"cannot requeue {arguments.activity_id} from {record['status']}")
  record["status"] = "pending"
  record.pop("started_at", None)
  record.setdefault("notes", []).append(f"Requeued: {arguments.reason}")
  save_progress_and_state(plan, progress)
  print(f"requeued {arguments.activity_id}")
  return 0


def command_record_test(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  require_activity(plan, arguments.activity_id)
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] != "in_progress":
    raise PlanError("test evidence may only be recorded for an in_progress activity")
  if arguments.phase == "red" and arguments.exit_code == 0:
    raise PlanError("red evidence must have a nonzero exit code")
  if arguments.phase == "green" and arguments.exit_code != 0:
    raise PlanError("green evidence must have exit code 0")
  record.setdefault("evidence", []).append({
    "phase": arguments.phase,
    "command": arguments.command,
    "exit_code": arguments.exit_code,
    "summary": arguments.summary,
    "recorded_at": utc_now(),
  })
  save_progress_and_state(plan, progress)
  print(f"recorded {arguments.phase} evidence for {arguments.activity_id}")
  return 0


def command_block(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  require_activity(plan, arguments.activity_id)
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] not in {"pending", "in_progress", "needs_review"}:
    raise PlanError(f"cannot block {arguments.activity_id} from {record['status']}")
  record["status"] = "blocked"
  record["blocked_at"] = utc_now()
  record["block_reason"] = arguments.reason
  record.setdefault("notes", []).append(f"Blocked: {arguments.reason}")
  save_progress_and_state(plan, progress)
  print(f"blocked {arguments.activity_id}")
  return 0


def command_unblock(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  require_activity(plan, arguments.activity_id)
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] != "blocked":
    raise PlanError(f"cannot unblock {arguments.activity_id} from {record['status']}")
  record["status"] = "pending"
  record.pop("blocked_at", None)
  record.pop("block_reason", None)
  record.setdefault("notes", []).append("Unblocked")
  save_progress_and_state(plan, progress)
  print(f"unblocked {arguments.activity_id}")
  return 0


def completion_evidence_issues(activity: dict[str, Any], record: dict[str, Any]) -> list[str]:
  evidence = record.get("evidence", [])
  green_positions = [
    index for index, item in enumerate(evidence)
    if item.get("phase") == "green" and item.get("exit_code") == 0
  ]
  if not green_positions:
    return ["successful green evidence is required"]
  if activity["test_policy"] == "validation":
    return []
  red_positions = [
    index for index, item in enumerate(evidence)
    if item.get("phase") == "red" and item.get("exit_code") != 0
  ]
  if not red_positions:
    return ["failing red evidence is required"]
  if min(green_positions) < min(red_positions):
    return ["red evidence must be recorded before green evidence"]
  return []


def command_complete(arguments: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  activity = require_activity(plan, arguments.activity_id)
  record = ensure_record(progress, arguments.activity_id)
  if record["status"] != "in_progress":
    raise PlanError(f"cannot complete {arguments.activity_id} from {record['status']}")
  issues = completion_evidence_issues(activity, record)
  if issues:
    raise PlanError("; ".join(issues))
  record["status"] = "completed"
  record["completed_at"] = utc_now()
  save_progress_and_state(plan, progress)
  print(f"completed {arguments.activity_id}")
  return 0


def command_reference_report(_: argparse.Namespace) -> int:
  plan, progress = load_documents()
  assert_valid_core(plan, progress)
  report = inspect_references(plan)
  print(json.dumps(report, indent=2))
  return 1 if any(item["status"] != "ok" for item in report.values()) else 0


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  subparsers = parser.add_subparsers(dest="command", required=True)

  check = subparsers.add_parser("check", help="validate all planning state")
  check.add_argument("--strict", action="store_true", help="also validate completed Git commits")
  check.set_defaults(function=command_check)

  next_parser = subparsers.add_parser("next", help="show the next ready activity")
  next_parser.add_argument("--json", action="store_true", help="print the full activity as JSON")
  next_parser.set_defaults(function=command_next)

  start = subparsers.add_parser("start", help="start a ready activity")
  start.add_argument("activity_id")
  start.set_defaults(function=command_start)

  requeue = subparsers.add_parser(
    "requeue", help="return an in-progress activity to pending",
  )
  requeue.add_argument("activity_id")
  requeue.add_argument("--reason", required=True)
  requeue.set_defaults(function=command_requeue)

  record = subparsers.add_parser("record-test", help="record red or green test evidence")
  record.add_argument("activity_id")
  record.add_argument("--phase", required=True, choices=("red", "green"))
  record.add_argument("--command", required=True)
  record.add_argument("--exit-code", required=True, type=int)
  record.add_argument("--summary", required=True)
  record.set_defaults(function=command_record_test)

  block = subparsers.add_parser("block", help="record a genuine activity blocker")
  block.add_argument("activity_id")
  block.add_argument("--reason", required=True)
  block.set_defaults(function=command_block)

  unblock = subparsers.add_parser("unblock", help="return a blocked activity to pending")
  unblock.add_argument("activity_id")
  unblock.set_defaults(function=command_unblock)

  complete = subparsers.add_parser("complete", help="complete a verified activity")
  complete.add_argument("activity_id")
  complete.set_defaults(function=command_complete)

  refresh = subparsers.add_parser("refresh", help="regenerate deterministic state")
  refresh.set_defaults(function=command_refresh)

  report = subparsers.add_parser("reference-report", help="inspect pinned reference mappings")
  report.set_defaults(function=command_reference_report)
  return parser


def main(argv: list[str] | None = None) -> int:
  parser = build_parser()
  arguments = parser.parse_args(argv)
  try:
    return arguments.function(arguments)
  except PlanError as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
