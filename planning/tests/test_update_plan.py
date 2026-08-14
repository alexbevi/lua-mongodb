from __future__ import annotations

import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "update_plan.py"
SPEC = importlib.util.spec_from_file_location("update_plan", MODULE_PATH)
assert SPEC and SPEC.loader
update_plan = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_plan)


def activity(activity_id: str, dependencies: list[str] | None = None, policy: str = "red_green") -> dict:
  return {
    "id": activity_id,
    "title": activity_id,
    "milestone": "m1",
    "depends_on": dependencies or [],
    "references": ["source:landmark"],
    "test_policy": policy,
    "test_first": "Specify behavior.",
    "implementation": "Implement behavior.",
    "verification": ["test"],
    "acceptance": ["passes"],
    "docs": ["README.md"],
    "commit": f"feat(test): implement {activity_id}",
  }


def minimal_plan(activities: list[dict] | None = None) -> dict:
  return {
    "schema_version": 1,
    "plan_id": "test-plan",
    "target": {},
    "references": {
      "source": {
        "path": "source",
        "url": "https://example.invalid/source.git",
        "commit": "0" * 40,
        "mappings": [{"name": "landmark", "path": "landmark.py", "symbol": "Landmark"}],
      }
    },
    "milestones": [{"id": "m1", "goal": "test"}],
    "tracks": [],
    "activities": activities or [activity("TST-001")],
  }


def tracked_plan() -> dict:
  prerequisite = activity("PRE-001")
  unrelated = activity("ADV-001", ["PRE-001"])
  entry = activity("PLN-001", ["PRE-001"])
  entry["track"] = "lua-hardening"
  terminal = activity("PLN-002", ["PLN-001"])
  terminal["track"] = "lua-hardening"
  plan = minimal_plan([prerequisite, unrelated, entry, terminal])
  plan["tracks"] = [{
    "id": "lua-hardening",
    "goal": "Harden Lua architecture.",
    "entry_activity": "PLN-001",
    "terminal_activity": "PLN-002",
    "after_activity": "PRE-001",
  }]
  return plan


def progress_for(plan: dict, statuses: dict[str, str] | None = None) -> dict:
  statuses = statuses or {}
  return {
    "schema_version": 1,
    "plan_id": plan["plan_id"],
    "plan_digest": update_plan.digest_plan(plan),
    "activities": {
      item["id"]: {"status": statuses.get(item["id"], "pending"), "evidence": [], "notes": []}
      for item in plan["activities"] if item["id"] in statuses
    },
    "verified_references": {},
  }


def git(path: Path, *arguments: str) -> str:
  result = subprocess.run(
    ["git", "-C", str(path), *arguments], check=True, text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
  )
  return result.stdout.strip()


class JsonTests(unittest.TestCase):
  def test_missing_and_malformed_json_are_explained(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      with self.assertRaisesRegex(update_plan.PlanError, "missing JSON"):
        update_plan.read_json(root / "missing.json")
      malformed = root / "bad.json"
      malformed.write_text("{", encoding="utf-8")
      with self.assertRaisesRegex(update_plan.PlanError, "malformed JSON"):
        update_plan.read_json(malformed)


class GraphTests(unittest.TestCase):
  def test_unknown_dependency_and_cycle_are_rejected(self) -> None:
    unknown = minimal_plan([activity("TST-001", ["TST-999"])])
    self.assertTrue(any("unknown dependency" in issue for issue in update_plan.validate_plan(unknown)))

    cyclic = minimal_plan([
      activity("TST-001", ["TST-002"]),
      activity("TST-002", ["TST-001"]),
    ])
    self.assertTrue(any("dependency cycle" in issue for issue in update_plan.validate_plan(cyclic)))

  def test_state_is_deterministic_and_dependency_ordered(self) -> None:
    plan = minimal_plan([
      activity("TST-001"),
      activity("TST-002", ["TST-001"]),
    ])
    progress = progress_for(plan, {"TST-001": "completed"})
    report = {
      "source": {
        "expected": "0" * 40, "actual": "0" * 40,
        "status": "ok", "issues": [], "path": "source",
      }
    }
    first = update_plan.compute_state(plan, progress, report)
    second = update_plan.compute_state(plan, progress, report)
    self.assertEqual(first, second)
    self.assertEqual(first["ready"], ["TST-002"])
    self.assertEqual(first["next_ready"], "TST-002")

  def test_track_declarations_and_membership_are_validated(self) -> None:
    plan = tracked_plan()
    self.assertEqual(update_plan.validate_plan(plan), [])

    duplicate = copy.deepcopy(plan)
    duplicate["tracks"].append(copy.deepcopy(duplicate["tracks"][0]))
    self.assertTrue(any(
      "duplicate track id" in issue for issue in update_plan.validate_plan(duplicate)
    ))

    undeclared = copy.deepcopy(plan)
    undeclared["activities"][1]["track"] = "unplanned"
    self.assertTrue(any(
      "unknown track" in issue for issue in update_plan.validate_plan(undeclared)
    ))

    mismatched_entry = copy.deepcopy(plan)
    mismatched_entry["tracks"][0]["entry_activity"] = "ADV-001"
    self.assertTrue(any(
      "entry activity" in issue for issue in update_plan.validate_plan(mismatched_entry)
    ))

    unknown_terminal = copy.deepcopy(plan)
    unknown_terminal["tracks"][0]["terminal_activity"] = "PLN-999"
    self.assertTrue(any(
      "unknown terminal activity" in issue
      for issue in update_plan.validate_plan(unknown_terminal)
    ))

  def test_state_groups_ready_activities_by_track(self) -> None:
    plan = tracked_plan()
    progress = progress_for(plan, {"PRE-001": "completed"})
    report = {
      "source": {
        "expected": "0" * 40, "actual": "0" * 40,
        "status": "ok", "issues": [], "path": "source",
      }
    }

    state = update_plan.compute_state(plan, progress, report)

    self.assertEqual(state["ready"], ["ADV-001", "PLN-001"])
    self.assertEqual(state["ready_by_track"], {"lua-hardening": ["PLN-001"]})
    self.assertEqual(state["next_ready"], "ADV-001")

  def test_next_selects_only_the_requested_track(self) -> None:
    plan = tracked_plan()
    progress = progress_for(plan, {"PRE-001": "completed"})
    report = {
      "source": {
        "expected": "0" * 40, "actual": "0" * 40,
        "status": "ok", "issues": [], "path": "source",
      }
    }
    state = update_plan.compute_state(plan, progress, report)
    parsed = update_plan.build_parser().parse_args([
      "next", "--track", "lua-hardening",
    ])
    self.assertEqual("lua-hardening", parsed.track)

    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)), \
        mock.patch.object(update_plan, "compute_state", return_value=state):
      output = io.StringIO()
      with contextlib.redirect_stdout(output):
        result = update_plan.command_next(argparse.Namespace(
          json=False,
          track="lua-hardening",
        ))
      self.assertEqual(0, result)
      self.assertEqual("PLN-001: PLN-001", output.getvalue().strip())

      output = io.StringIO()
      with contextlib.redirect_stdout(output):
        result = update_plan.command_next(argparse.Namespace(json=False, track=None))
      self.assertEqual(0, result)
      self.assertEqual("ADV-001: ADV-001", output.getvalue().strip())

      with self.assertRaisesRegex(update_plan.PlanError, "unknown track"):
        update_plan.command_next(argparse.Namespace(json=False, track="unknown"))


class EvidenceTests(unittest.TestCase):
  def test_red_green_completion_requires_ordered_evidence(self) -> None:
    item = activity("TST-001")
    record = {"evidence": []}
    self.assertIn("green", update_plan.completion_evidence_issues(item, record)[0])
    record["evidence"] = [{"phase": "green", "exit_code": 0}]
    self.assertIn("red", update_plan.completion_evidence_issues(item, record)[0])
    record["evidence"] = [
      {"phase": "green", "exit_code": 0},
      {"phase": "red", "exit_code": 1},
    ]
    self.assertIn("before", update_plan.completion_evidence_issues(item, record)[0])
    record["evidence"] = [
      {"phase": "red", "exit_code": 1},
      {"phase": "green", "exit_code": 0},
    ]
    self.assertEqual(update_plan.completion_evidence_issues(item, record), [])

  def test_validation_activity_needs_only_green(self) -> None:
    item = activity("TST-001", policy="validation")
    record = {"evidence": [{"phase": "green", "exit_code": 0}]}
    self.assertEqual(update_plan.completion_evidence_issues(item, record), [])

  def test_start_enforces_dependencies_and_single_active_activity(self) -> None:
    plan = minimal_plan([
      activity("TST-001"),
      activity("TST-002", ["TST-001"]),
    ])
    progress = progress_for(plan)
    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)):
      with self.assertRaisesRegex(update_plan.PlanError, "dependencies"):
        update_plan.command_start(argparse.Namespace(activity_id="TST-002"))

    progress = progress_for(plan, {"TST-001": "in_progress"})
    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)):
      with self.assertRaisesRegex(update_plan.PlanError, "already in_progress"):
        update_plan.command_start(argparse.Namespace(activity_id="TST-002"))

  def test_start_requires_completed_activity_commits_to_be_pushed(self) -> None:
    plan = minimal_plan([
      activity("TST-001"),
      activity("TST-002", ["TST-001"]),
    ])
    progress = progress_for(plan, {"TST-001": "completed"})
    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)):
      with mock.patch.object(
        update_plan, "git_commit_issues", return_value=["TST-001 is not pushed"],
      ) as commit_check:
        with self.assertRaisesRegex(update_plan.PlanError, "unique and pushed"):
          update_plan.command_start(argparse.Namespace(activity_id="TST-002"))
    commit_check.assert_called_once_with(plan, progress, require_pushed=True)

  def test_requeue_returns_only_an_active_activity_to_pending(self) -> None:
    plan = minimal_plan()
    progress = progress_for(plan, {"TST-001": "in_progress"})
    progress["activities"]["TST-001"]["started_at"] = "2026-01-01T00:00:00+00:00"

    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)), \
        mock.patch.object(update_plan, "save_progress_and_state") as save:
      result = update_plan.command_requeue(argparse.Namespace(
        activity_id="TST-001",
        reason="roadmap dependencies changed",
      ))

    self.assertEqual(0, result)
    record = progress["activities"]["TST-001"]
    self.assertEqual("pending", record["status"])
    self.assertNotIn("started_at", record)
    self.assertEqual(["Requeued: roadmap dependencies changed"], record["notes"])
    save.assert_called_once_with(plan, progress)

    pending = progress_for(plan, {"TST-001": "pending"})
    with mock.patch.object(update_plan, "load_documents", return_value=(plan, pending)):
      with self.assertRaisesRegex(update_plan.PlanError, "cannot requeue"):
        update_plan.command_requeue(argparse.Namespace(
          activity_id="TST-001",
          reason="not active",
        ))

  def test_requeue_reopens_completed_activity_with_a_commit_boundary(self) -> None:
    plan = minimal_plan([
      activity("TST-001"),
      activity("TST-002", ["TST-001"]),
    ])
    progress = progress_for(plan, {"TST-001": "completed"})
    record = progress["activities"]["TST-001"]
    record["completed_at"] = "2026-01-01T00:00:00+00:00"
    record["evidence"] = [{"phase": "green", "exit_code": 0}]
    boundary = "a" * 40
    result = subprocess.CompletedProcess(
      ["git", "rev-parse", "HEAD"],
      0,
      stdout=boundary + "\n",
      stderr="",
    )

    with mock.patch.object(update_plan, "load_documents", return_value=(plan, progress)), \
        mock.patch.object(update_plan, "run_git", return_value=result), \
        mock.patch.object(update_plan, "save_progress_and_state") as save:
      status = update_plan.command_requeue(argparse.Namespace(
        activity_id="TST-001",
        reason="split broad activity",
      ))

    self.assertEqual(0, status)
    self.assertEqual("pending", record["status"])
    self.assertEqual([], record["evidence"])
    self.assertNotIn("completed_at", record)
    self.assertEqual(boundary, record["reopened_after_commit"])
    self.assertEqual(
      [{
        "completed_at": "2026-01-01T00:00:00+00:00",
        "evidence": [{"phase": "green", "exit_code": 0}],
      }],
      record["reopen_history"],
    )
    save.assert_called_once_with(plan, progress)


class ReferenceTests(unittest.TestCase):
  def make_reference(self, root: Path) -> tuple[dict, str, str]:
    checkout = root / "source"
    checkout.mkdir()
    git(checkout, "init", "-b", "main")
    git(checkout, "config", "user.name", "Test")
    git(checkout, "config", "user.email", "test@example.invalid")
    (checkout / "landmark.py").write_text("class Landmark:\n  pass\n", encoding="utf-8")
    git(checkout, "add", "landmark.py")
    git(checkout, "commit", "-m", "first")
    first = git(checkout, "rev-parse", "HEAD")
    (checkout / "landmark.py").write_text("class Replacement:\n  pass\n", encoding="utf-8")
    git(checkout, "add", "landmark.py")
    git(checkout, "commit", "-m", "second")
    second = git(checkout, "rev-parse", "HEAD")
    plan = minimal_plan()
    return plan, first, second

  def test_missing_and_drifted_checkout_are_stale(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      plan = minimal_plan()
      missing = update_plan.inspect_references(plan, root)
      self.assertEqual(missing["source"]["status"], "stale")
      self.assertIn("missing checkout", missing["source"]["issues"][0])

      plan, first, _ = self.make_reference(root)
      plan["references"]["source"]["commit"] = first
      drifted = update_plan.inspect_references(plan, root)
      self.assertEqual(drifted["source"]["status"], "stale")
      self.assertTrue(any("expected" in issue for issue in drifted["source"]["issues"]))

  def test_removed_mapped_symbol_is_stale(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      plan, _, second = self.make_reference(root)
      plan["references"]["source"]["commit"] = second
      report = update_plan.inspect_references(plan, root)
      self.assertTrue(any("missing mapped symbol" in issue for issue in report["source"]["issues"]))


class CommitTests(unittest.TestCase):
  def test_strict_commit_check_requires_exact_subject_and_trailer(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      (root / "file").write_text("ok", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      self.assertEqual(update_plan.git_commit_issues(plan, progress, root), [])
      plan["activities"][0]["commit"] = "feat(test): different subject"
      self.assertTrue(any("exact commit subject" in issue for issue in update_plan.git_commit_issues(plan, progress, root)))

  def test_strict_commit_check_requires_unique_activity_commit(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      (root / "file").write_text("first", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      (root / "file").write_text("second", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      self.assertTrue(any("exactly one commit" in issue for issue in update_plan.git_commit_issues(plan, progress, root)))

  def test_strict_commit_check_rejects_reused_activity_trailer(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      (root / "file").write_text("first", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      (root / "file").write_text("follow-up", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "fix(test): follow up", "-m", "Plan-Activity: TST-001")
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      self.assertTrue(any("trailer is reused" in issue for issue in update_plan.git_commit_issues(plan, progress, root)))

  def test_strict_commit_check_ignores_commits_before_reopen_boundary(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      (root / "file").write_text("first", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      (root / "file").write_text("boundary", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "chore(test): reopen activity")
      boundary = git(root, "rev-parse", "HEAD")
      (root / "file").write_text("replacement", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      progress["activities"]["TST-001"]["reopened_after_commit"] = boundary

      self.assertEqual(update_plan.git_commit_issues(plan, progress, root), [])

  def test_strict_commit_check_rejects_multiple_activity_trailers(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      (root / "file").write_text("ok", encoding="utf-8")
      git(root, "add", "file")
      git(
        root, "commit", "-m", "feat(test): implement TST-001", "-m",
        "Plan-Activity: TST-001\nPlan-Activity: TST-002",
      )
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      self.assertTrue(any("multiple Plan-Activity trailers" in issue for issue in update_plan.git_commit_issues(plan, progress, root)))

  def test_pushed_commit_check_requires_remote_reachability(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary) / "checkout"
      remote = Path(temporary) / "remote.git"
      root.mkdir()
      remote.mkdir()
      git(root, "init", "-b", "main")
      git(root, "config", "user.name", "Test")
      git(root, "config", "user.email", "test@example.invalid")
      git(remote, "init", "--bare")
      git(root, "remote", "add", "origin", str(remote))
      (root / "file").write_text("ok", encoding="utf-8")
      git(root, "add", "file")
      git(root, "commit", "-m", "feat(test): implement TST-001", "-m", "Plan-Activity: TST-001")
      plan = minimal_plan()
      progress = progress_for(plan, {"TST-001": "completed"})
      self.assertTrue(any("not present on a remote" in issue for issue in update_plan.git_commit_issues(
        plan, progress, root, require_pushed=True,
      )))
      git(root, "push", "-u", "origin", "main")
      self.assertEqual(update_plan.git_commit_issues(plan, progress, root, require_pushed=True), [])


if __name__ == "__main__":
  unittest.main()
