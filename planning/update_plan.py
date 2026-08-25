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
TRACK_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
# Published history before commit-policy enforcement contains CI follow-ups that
# reused CI-001's trailer. Do not rewrite that history; reject every new reuse.
COMMIT_POLICY_BASELINE = "057026301066f9d4adcf22d59710a3e5690ec529"


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


def declared_track_ids(plan: dict[str, Any]) -> list[str]:
  tracks = plan.get("tracks")
  if not isinstance(tracks, list):
    return []
  return [
    track["id"] for track in tracks
    if isinstance(track, dict) and isinstance(track.get("id"), str)
  ]


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
  track_definitions: dict[str, dict[str, Any]] = {}
  tracks = plan.get("tracks")
  if not isinstance(tracks, list):
    issues.append("plan.tracks must be an array")
    tracks = []
  for index, track in enumerate(tracks):
    if not isinstance(track, dict):
      issues.append(f"track at index {index} must be an object")
      continue
    for key in ("id", "goal", "entry_activity", "terminal_activity", "after_activity"):
      if key not in track:
        issues.append(f"track at index {index} is missing {key}")
    track_id = track.get("id")
    if not isinstance(track_id, str) or not TRACK_RE.fullmatch(track_id):
      issues.append(f"track at index {index} has invalid id {track_id}")
      continue
    if track_id in track_definitions:
      issues.append(f"duplicate track id: {track_id}")
      continue
    track_definitions[track_id] = track
    if not isinstance(track.get("goal"), str) or not track.get("goal"):
      issues.append(f"track {track_id} goal must be a non-empty string")
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
    activity_track = activity.get("track")
    if activity_track is not None:
      if not isinstance(activity_track, str) or not TRACK_RE.fullmatch(activity_track):
        issues.append(f"activity {activity_id} has invalid track {activity_track}")
      elif activity_track not in track_definitions:
        issues.append(f"activity {activity_id} has unknown track {activity_track}")
    if not COMMIT_RE.fullmatch(str(activity.get("commit", ""))):
      issues.append(f"activity {activity_id} has invalid Conventional Commit subject")
    for mapping_id in activity.get("references", []):
      if mapping_id not in mapping_ids:
        issues.append(f"activity {activity_id} has unknown reference {mapping_id}")

  for track_id, track in track_definitions.items():
    for field, label in (
      ("entry_activity", "entry"),
      ("terminal_activity", "terminal"),
      ("after_activity", "after"),
    ):
      referenced_id = track.get(field)
      if not isinstance(referenced_id, str) or referenced_id not in activities:
        issues.append(f"track {track_id} has unknown {label} activity {referenced_id}")
    entry_id = track.get("entry_activity")
    if entry_id in activities and activities[entry_id].get("track") != track_id:
      issues.append(f"track {track_id} entry activity {entry_id} is not assigned to the track")
    terminal_id = track.get("terminal_activity")
    if terminal_id in activities and activities[terminal_id].get("track") != track_id:
      issues.append(f"track {track_id} terminal activity {terminal_id} is not assigned to the track")
    after_id = track.get("after_activity")
    if entry_id in activities and after_id in activities:
      if after_id not in activities[entry_id].get("depends_on", []):
        issues.append(f"track {track_id} entry activity {entry_id} does not depend on {after_id}")

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
  ready_by_track = {track_id: [] for track_id in declared_track_ids(plan)}
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
      activity_track = activity.get("track")
      if activity_track in ready_by_track:
        ready_by_track[activity_track].append(activity_id)
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
    "ready_by_track": ready_by_track,
    "blocked": blocked,
    "needs_review": needs_review,
    "stale": stale,
    "next_ready": ready[0] if ready else None,
  }


def remote_refs_containing(root: Path, commit: str) -> list[str]:
  result = run_git(root, [
    "for-each-ref", f"--contains={commit}", "--format=%(refname)", "refs/remotes",
  ])
  if result.returncode != 0:
    return []
  return [line for line in result.stdout.splitlines() if line]


def predates_commit_policy(root: Path, commit: str) -> bool:
  result = run_git(root, ["merge-base", "--is-ancestor", commit, COMMIT_POLICY_BASELINE])
  return result.returncode == 0


def git_commit_issues(
  plan: dict[str, Any], progress: dict[str, Any], root: Path = ROOT,
  require_pushed: bool = False,
) -> list[str]:
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
    record = progress.get("activities", {}).get(activity_id, {})
    reopen_boundary = record.get("reopened_after_commit")
    eligible_commits = commits

    if reopen_boundary:
      eligible_commits = [
        item for item in commits
        if item[0] != reopen_boundary
        and run_git(
          root,
          ["merge-base", "--is-ancestor", reopen_boundary, item[0]],
        ).returncode == 0
      ]

    trailer = f"Plan-Activity: {activity_id}"
    matching = [
      item for item in eligible_commits if trailer in item[2].splitlines()
    ]
    if not matching:
      issues.append(f"completed activity {activity_id} has no commit trailer")
      continue
    exact = [item for item in matching if item[1] == activity["commit"]]
    if not exact:
      issues.append(f"completed activity {activity_id} has no exact commit subject")
      continue
    if len(exact) != 1:
      issues.append(f"completed activity {activity_id} must have exactly one commit with its exact subject and trailer")
      continue
    commit, _, body = exact[0]
    policy_era_extras = [
      item for item in matching
      if item[0] != commit and not predates_commit_policy(root, item[0])
    ]
    if policy_era_extras:
      issues.append(f"completed activity {activity_id} trailer is reused by another commit")
      continue
    activity_trailers = [
      line for line in body.splitlines() if line.startswith("Plan-Activity:")
    ]
    if activity_trailers != [trailer]:
      issues.append(f"completed activity {activity_id} commit has multiple Plan-Activity trailers")
    if require_pushed and not remote_refs_containing(root, commit):
      issues.append(f"completed activity {activity_id} commit {commit[:12]} is not present on a remote-tracking ref")
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
    if arguments.pushed and not arguments.strict:
      issues.append("--pushed requires --strict")
    if arguments.strict:
      issues.extend(git_commit_issues(plan, progress, require_pushed=arguments.pushed))
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
  track_id = getattr(arguments, "track", None)
  if track_id is not None:
    if track_id not in declared_track_ids(plan):
      raise PlanError(f"unknown track: {track_id}")
    track_ready = state["ready_by_track"][track_id]
    activity_id = track_ready[0] if track_ready else None
  else:
    activity_id = state["next_ready"]
  if activity_id is None:
    if arguments.json:
      print("null")
    elif track_id is not None:
      print(f"no ready activity in track {track_id}")
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
  requested_track = getattr(arguments, "track", None)
  if requested_track is not None and requested_track not in declared_track_ids(plan):
    raise PlanError(f"unknown track: {requested_track}")
  activity_track = activity.get("track")
  if activity.get("milestone") == "additional" and requested_track is None:
    raise PlanError(f"additional activity {arguments.activity_id} requires --track authorization")
  if requested_track is not None and activity_track != requested_track:
    raise PlanError(
      f"activity {arguments.activity_id} does not belong to track {requested_track}"
    )
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
  commit_issues = git_commit_issues(plan, progress, require_pushed=True)
  if commit_issues:
    raise PlanError(
      "cannot start another activity until completed activity commits are unique and pushed:\n"
      + "\n".join(commit_issues)
    )
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
  previous_status = record["status"]

  if previous_status not in {"in_progress", "completed"}:
    raise PlanError(f"cannot requeue {arguments.activity_id} from {record['status']}")

  if previous_status == "completed":
    completed_dependents = [
      activity["id"] for activity in plan["activities"]
      if arguments.activity_id in activity["depends_on"]
      and status_for(progress, activity["id"]) == "completed"
    ]

    if completed_dependents:
      raise PlanError(
        f"cannot reopen {arguments.activity_id}; completed dependents: "
        + ", ".join(completed_dependents)
      )

    probe = run_git(ROOT, ["rev-parse", "HEAD"])

    if probe.returncode != 0:
      raise PlanError(f"cannot record reopen commit boundary: {probe.stderr.strip()}")

    record.setdefault("reopen_history", []).append({
      "completed_at": record.get("completed_at"),
      "evidence": list(record.get("evidence", [])),
    })
    record["evidence"] = []
    record["reopened_after_commit"] = probe.stdout.strip()
    record.pop("completed_at", None)

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
  check.add_argument(
    "--pushed", action="store_true",
    help="with --strict, require completed commits on a remote-tracking ref",
  )
  check.set_defaults(function=command_check)

  next_parser = subparsers.add_parser("next", help="show the next ready activity")
  next_parser.add_argument("--json", action="store_true", help="print the full activity as JSON")
  next_parser.add_argument("--track", help="select only ready activities in this track")
  next_parser.set_defaults(function=command_next)

  start = subparsers.add_parser("start", help="start a ready activity")
  start.add_argument("activity_id")
  start.add_argument("--track", help="authorize this declared track for an additional-task start")
  start.set_defaults(function=command_start)

  requeue = subparsers.add_parser(
    "requeue", help="return an in-progress or completed activity to pending",
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
