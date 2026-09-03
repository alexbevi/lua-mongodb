from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "update_references.py"
SPEC = importlib.util.spec_from_file_location("update_references", MODULE_PATH)
assert SPEC and SPEC.loader
update_references = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_references)


def git(directory: Path, *arguments: str) -> str:
  result = subprocess.run(
    ["git", "-C", str(directory), *arguments],
    check=True,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
  )
  return result.stdout.strip()


def make_checkout(root: Path) -> tuple[Path, str, str]:
  checkout = root / "source"
  checkout.mkdir()
  git(checkout, "init", "-b", "main")
  git(checkout, "config", "user.name", "Test")
  git(checkout, "config", "user.email", "test@example.invalid")
  (checkout / "landmark.py").write_text("class Landmark:\n  pass\n", encoding="utf-8")
  git(checkout, "add", "landmark.py")
  git(checkout, "commit", "-m", "first")
  first = git(checkout, "rev-parse", "HEAD")
  (checkout / "landmark.py").write_text(
    "class Landmark:\n  value = 1\n", encoding="utf-8",
  )
  git(checkout, "add", "landmark.py")
  git(checkout, "commit", "-m", "second")
  second = git(checkout, "rev-parse", "HEAD")
  git(checkout, "checkout", "--detach", first)
  return checkout, first, second


def make_specifications_checkout(root: Path) -> tuple[Path, str, str]:
  checkout = root / "specifications"
  fixture = checkout / "source" / "example" / "tests" / "unified" / "case.json"
  document = checkout / "source" / "example" / "example.md"
  fixture.parent.mkdir(parents=True)
  document.parent.mkdir(parents=True, exist_ok=True)
  git(checkout, "init", "-b", "main")
  git(checkout, "config", "user.name", "Test")
  git(checkout, "config", "user.email", "test@example.invalid")
  document.write_text("# Example\n\n- Status: Accepted\n", encoding="utf-8")
  fixture.write_text(
    json.dumps({
      "description": "example",
      "schemaVersion": "1.0",
      "createEntities": [],
      "tests": [{"description": "first", "operations": []}],
    }),
    encoding="utf-8",
  )
  git(checkout, "add", ".")
  git(checkout, "commit", "-m", "first")
  first = git(checkout, "rev-parse", "HEAD")
  document.write_text("# Example\n\n- Status: Accepted\n\nChanged.\n", encoding="utf-8")
  fixture.write_text(
    json.dumps({
      "description": "example",
      "schemaVersion": "1.0",
      "createEntities": [],
      "tests": [
        {"description": "first changed", "operations": []},
        {"description": "second", "operations": []},
      ],
    }),
    encoding="utf-8",
  )
  git(checkout, "add", ".")
  git(checkout, "commit", "-m", "second")
  second = git(checkout, "rev-parse", "HEAD")
  git(checkout, "checkout", "--detach", first)
  return checkout, first, second


def write_references(root: Path, first: str) -> Path:
  path = root / "references.json"
  path.write_text(
    json.dumps({
      "schema_version": 1,
      "references": {
        "source": {
          "path": "source",
          "url": "https://example.invalid/source.git",
          "commit": first,
          "mappings": [{
            "name": "landmark",
            "path": "landmark.py",
            "symbol": "Landmark",
          }],
        },
      },
    }),
    encoding="utf-8",
  )
  return path


def write_plan(root: Path) -> tuple[Path, Path]:
  planning = root / "planning"
  planning.mkdir(exist_ok=True)
  plan_path = planning / "plan.json"
  progress_path = planning / "progress.json"
  plan_path.write_text(
    json.dumps({
      "activities": [{
        "id": "REF-001",
        "references": ["source:landmark"],
      }],
    }),
    encoding="utf-8",
  )
  progress_path.write_text(
    json.dumps({
      "activities": {
        "REF-001": {"status": "completed"},
      },
    }),
    encoding="utf-8",
  )
  return plan_path, progress_path


def make_project_with_reference(
  root: Path,
  generator_source: str,
) -> tuple[Path, Path, str, str]:
  upstream_root = root / "upstream-root"
  upstream_root.mkdir()
  checkout, first, second = make_checkout(upstream_root)
  project = root / "project"
  project.mkdir()
  git(project, "init", "-b", "main")
  git(project, "config", "user.name", "Test")
  git(project, "config", "user.email", "test@example.invalid")
  planning = project / "planning"
  planning.mkdir()
  (planning / "generate.py").write_text(generator_source, encoding="utf-8")
  (planning / "references.json").write_text(
    json.dumps({
      "schema_version": 1,
      "references": {
        "source": {
          "path": "planning/source",
          "url": str(checkout),
          "commit": first,
          "mappings": [{
            "name": "landmark",
            "path": "landmark.py",
            "symbol": "Landmark",
          }],
        },
      },
    }),
    encoding="utf-8",
  )
  (project / "generated.txt").write_text("old\n", encoding="utf-8")
  git(
    project,
    "-c",
    "protocol.file.allow=always",
    "submodule",
    "add",
    str(checkout),
    "planning/source",
  )
  git(project, "add", ".")
  git(project, "commit", "-m", "project")
  return project, checkout, first, second


class ReferenceUpdateTests(unittest.TestCase):
  def test_proposed_plan_items_group_review_work(self) -> None:
    report = {
      "affected_activities": [
        {
          "id": "REF-001",
          "mappings": ["source:landmark"],
          "status": "completed",
        },
        {
          "id": "REF-002",
          "mappings": ["source:landmark"],
          "status": "pending",
        },
      ],
      "mapped_landmarks": [
        {"changed": True, "id": "source:landmark"},
        {"changed": False, "id": "source:stable"},
      ],
      "review_candidates": ["REF-001"],
      "simulation": {
        "first_run": [{"command": "planning/generate.py", "exit_code": 1}],
        "generated_files": [],
        "repeatable": True,
        "valid": False,
      },
      "specification_inventory": {
        "accepted_documents": {
          "added": [],
          "removed": [],
          "changed": [{
            "identity": "alpha/alpha.md",
            "from": {"suite": "alpha", "fingerprint": "old"},
            "to": {"suite": "alpha", "fingerprint": "new"},
          }],
        },
        "fixture_files": {
          "added": [{"identity": "alpha/tests/new.json", "suite": "alpha"}],
          "removed": [],
          "changed": [],
        },
        "cases": {
          "added": [],
          "removed": [],
          "changed": [],
        },
        "unified_tests": {
          "added": [{
            "identity": "beta/tests/unified/case.json::test[1]",
            "fixture": "beta/tests/unified/case.json",
          }],
          "removed": [],
          "changed": [],
        },
      },
    }

    items = update_references.propose_plan_items(report)

    self.assertEqual(
      [
        {
          "change_counts": {
            "accepted_documents": {"added": 0, "changed": 1, "removed": 0},
            "cases": {"added": 0, "changed": 0, "removed": 0},
            "fixture_files": {"added": 1, "changed": 0, "removed": 0},
            "unified_tests": {"added": 0, "changed": 0, "removed": 0},
          },
          "disposition": "actionable",
          "key": "specifications:alpha",
          "kind": "specification_suite_review",
          "owners": [],
          "reason": "the specification inventory changed",
          "title": "Review alpha specification changes",
        },
        {
          "change_counts": {
            "accepted_documents": {"added": 0, "changed": 0, "removed": 0},
            "cases": {"added": 0, "changed": 0, "removed": 0},
            "fixture_files": {"added": 0, "changed": 0, "removed": 0},
            "unified_tests": {"added": 1, "changed": 0, "removed": 0},
          },
          "disposition": "actionable",
          "key": "specifications:beta",
          "kind": "specification_suite_review",
          "owners": [],
          "reason": "the specification inventory changed",
          "title": "Review beta specification changes",
        },
        {
          "affected_activity_count": 2,
          "disposition": "actionable",
          "key": "source:landmark",
          "kind": "reference_mapping_review",
          "reason": "1 completed or active activity cites this mapping",
          "review_candidate_count": 1,
          "title": "Review source:landmark reference mapping changes",
        },
        {
          "command": "planning/generate.py",
          "disposition": "blocked",
          "key": "generator:planning/generate.py",
          "kind": "generator_failure",
          "reason": "the simulated generator exited with status 1",
          "title": "Resolve planning/generate.py generator failure",
        },
      ],
      items,
    )

    report["proposed_plan_items"] = items
    text = update_references.render_impact({
      **report,
      "changed_paths": [],
      "commits": [],
      "from_commit": "a" * 40,
      "reference": "source",
      "to_commit": "b" * 40,
      "valid": False,
    }, "text")
    self.assertIn(
      "proposed plan items: actionable=3, blocked=1, deferred=0, informational=0",
      text,
    )
    self.assertIn("actionable:", text)
    self.assertIn("1. Review alpha specification changes", text)
    self.assertIn("blocked:", text)
    self.assertIn("1. Resolve planning/generate.py generator failure", text)

  def test_text_output_hides_informational_proposals_by_default(self) -> None:
    report = {
      "affected_activities": [],
      "changed_paths": [],
      "commits": [],
      "from_commit": "a" * 40,
      "mapped_landmarks": [],
      "proposed_plan_items": [{
        "disposition": "informational",
        "key": "reference:docs",
        "kind": "reference_path_review",
        "reason": "only documentation changed",
        "title": "Review documentation changes",
      }],
      "reference": "source",
      "review_candidates": [],
      "to_commit": "b" * 40,
      "valid": True,
    }

    filtered = update_references.render_impact(report, "text")
    complete = update_references.render_impact(report, "text", "all")

    self.assertIn("informational=1", filtered)
    self.assertNotIn("Review documentation changes", filtered)
    self.assertIn("informational changes hidden; pass --show all", filtered)
    self.assertIn("Review documentation changes", complete)

  def test_specification_ownership_replaces_umbrella_activity_impacts(self) -> None:
    report = {
      "affected_activities": [{
        "id": "EVERYTHING-001",
        "mappings": ["specifications:source"],
        "status": "completed",
      }],
      "mapped_landmarks": [{
        "changed": True,
        "id": "specifications:source",
      }],
      "reference": "specifications",
      "review_candidates": ["EVERYTHING-001"],
      "simulation": {
        "specification_ownership": {
          "added": [{
            "activity": "FUTURE-001",
            "activity_status": "pending",
            "conformance_status": "deferred_unsupported",
            "identity": "case:beta/tests/new.json::case",
            "record_type": "case",
            "source_identity": "beta/tests/new.json::case",
            "suite": "beta",
          }],
          "changed": [{
            "from": {
              "activity": "DONE-001",
              "activity_status": "completed",
              "conformance_status": "passed",
              "record_type": "case",
              "source_identity": "alpha/tests/case.json::case",
              "suite": "alpha",
            },
            "identity": "case:alpha/tests/case.json::case",
            "to": {
              "activity": "DONE-001",
              "activity_status": "completed",
              "conformance_status": "passed",
              "record_type": "case",
              "source_identity": "alpha/tests/case.json::case",
              "suite": "alpha",
            },
          }],
          "removed": [],
        },
      },
      "specification_inventory": {
        family: {"added": [], "changed": [], "removed": []}
        for family in (
          "accepted_documents", "cases", "fixture_files", "unified_tests"
        )
      },
    }
    report["specification_inventory"]["cases"]["added"] = [{
      "identity": "beta/tests/new.json::case",
      "suite": "beta",
    }]
    report["specification_inventory"]["cases"]["changed"] = [{
      "from": {"suite": "alpha"},
      "identity": "alpha/tests/case.json::case",
      "to": {"suite": "alpha"},
    }]

    update_references.apply_specification_activity_impacts(report)
    items = update_references.propose_plan_items(report)

    self.assertEqual(
      [
        {
          "id": "DONE-001",
          "identities": ["alpha/tests/case.json::case"],
          "status": "completed",
          "suites": ["alpha"],
        },
        {
          "id": "FUTURE-001",
          "identities": ["beta/tests/new.json::case"],
          "status": "pending",
          "suites": ["beta"],
        },
      ],
      report["affected_activities"],
    )
    self.assertEqual(["DONE-001"], report["review_candidates"])
    self.assertEqual("actionable", items[0]["disposition"])
    self.assertEqual(["DONE-001"], items[0]["owners"])
    self.assertEqual("deferred", items[1]["disposition"])
    self.assertEqual(["FUTURE-001"], items[1]["owners"])
    self.assertEqual("informational", items[2]["disposition"])
    self.assertEqual(
      "exact specification ownership supersedes this broad mapping",
      items[2]["reason"],
    )

  def test_behavior_verification_is_separate_from_artifact_generation(self) -> None:
    ownership = {
      "added": [{
        "activity": "DONE-001",
        "activity_status": "completed",
        "conformance_status": "passed",
        "identity": "case:alpha/tests/new.json::case",
        "last_execution": "make test-focus FOCUS_UNIT=spec/unit/alpha_spec.lua",
        "record_type": "case",
        "required_environment": "none",
        "source_identity": "alpha/tests/new.json::case",
        "suite": "alpha",
      }],
      "changed": [{
        "from": {
          "activity": "FUTURE-001",
          "activity_status": "pending",
          "conformance_status": "deferred_unsupported",
          "last_execution": None,
          "record_type": "case",
          "required_environment": "deterministic-runtime",
          "source_identity": "beta/tests/case.json::case",
          "suite": "beta",
        },
        "identity": "case:beta/tests/case.json::case",
        "to": {
          "activity": "FUTURE-001",
          "activity_status": "pending",
          "conformance_status": "deferred_unsupported",
          "last_execution": None,
          "record_type": "case",
          "required_environment": "deterministic-runtime",
          "source_identity": "beta/tests/case.json::case",
          "suite": "beta",
        },
      }],
      "removed": [],
    }

    commands = update_references.propose_verification_commands(ownership)

    self.assertEqual(
      [{
        "command": "make test-focus FOCUS_UNIT=spec/unit/alpha_spec.lua",
        "identities": ["alpha/tests/new.json::case"],
        "required_environments": ["none"],
      }],
      commands,
    )
    report = {
      "artifact_status": "passed",
      "behavior_verification": update_references.build_behavior_verification(
        commands,
        [],
        required=True,
        ran=False,
      ),
      "valid": True,
    }
    self.assertEqual("passed", report["artifact_status"])
    self.assertEqual("required", report["behavior_verification"]["status"])
    self.assertEqual("not_run", report["behavior_verification"]["execution_status"])

  def test_impact_digest_is_canonical_and_reviewable(self) -> None:
    first = {
      "valid": True,
      "reference": "source",
      "changed_paths": [{"status": "M", "path": "landmark.py"}],
    }
    reordered = {
      "changed_paths": [{"path": "landmark.py", "status": "M"}],
      "reference": "source",
      "valid": True,
    }

    digest = update_references.impact_digest(first)

    self.assertEqual(digest, update_references.impact_digest(reordered))
    update_references.require_expected_impact(first, digest)
    with self.assertRaisesRegex(
      update_references.ReferenceUpdateError,
      "reviewed impact digest",
    ):
      update_references.require_expected_impact(first, "0" * 64)

  def test_verification_results_do_not_change_the_impact_digest(self) -> None:
    command = {
      "command": "make test-focus FOCUS_UNIT=spec/unit/example_spec.lua",
      "identities": ["example/tests/case.json::case"],
      "required_environments": ["none"],
    }
    not_run = {
      "behavior_verification": {
        "commands": [command],
        "execution_status": "not_run",
        "results": [],
        "status": "required",
      },
      "valid": True,
    }
    passed = {
      "behavior_verification": {
        "commands": [command],
        "execution_status": "passed",
        "results": [{"command": command["command"], "exit_code": 0}],
        "status": "required",
      },
      "valid": True,
    }

    self.assertEqual(
      update_references.impact_digest(not_run),
      update_references.impact_digest(passed),
    )

  def test_failed_target_reports_the_nearest_green_waypoint(self) -> None:
    commits = ["1" * 40, "2" * 40, "3" * 40]
    checked = []

    def artifact_passes(commit: str) -> bool:
      checked.append(commit)
      return commit == commits[0]

    waypoint = update_references.find_green_waypoint(
      "0" * 40,
      commits,
      artifact_passes,
    )

    self.assertEqual(
      {
        "checked_commits": 2,
        "first_failing_commit": commits[1],
        "last_green_commit": commits[0],
      },
      waypoint,
    )
    self.assertEqual([commits[1], commits[0]], checked)

  def test_expected_impact_cli_flag_is_separate_from_dry_run(self) -> None:
    arguments = update_references.build_parser().parse_args([
      "source",
      "a" * 40,
      "--expect-impact",
      "b" * 64,
    ])

    self.assertFalse(arguments.dry_run)
    self.assertEqual("b" * 64, arguments.expect_impact)

  def test_reviewed_impact_applies_the_exact_simulated_update(self) -> None:
    generator = """\
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
references = json.loads((root / "planning/references.json").read_text())
commit = references["references"]["source"]["commit"]
(root / "generated.txt").write_text(commit + "\\n")
"""
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      project, _, _, second = make_project_with_reference(root, generator)
      references_path = project / "planning" / "references.json"
      report = update_references.build_impact_report(
        "source",
        second,
        root=project,
        references_path=references_path,
        plan_path=project / "planning" / "plan.json",
        progress_path=project / "planning" / "progress.json",
        generator_commands=(("planning/generate.py",),),
      )

      result = update_references.advance_reviewed_reference(
        "source",
        second,
        report["impact_digest"],
        root=project,
        references_path=references_path,
        plan_path=project / "planning" / "plan.json",
        progress_path=project / "planning" / "progress.json",
        generator_commands=(("planning/generate.py",),),
      )

      self.assertEqual({"M": 1}, result["summary"])
      self.assertTrue(result["artifacts_regenerated"])
      self.assertEqual(second, git(project / "planning" / "source", "rev-parse", "HEAD"))
      self.assertEqual(second + "\n", (project / "generated.txt").read_text())

  def test_reviewed_repeatable_failure_moves_only_the_pin(self) -> None:
    generator = """\
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
(root / "generated.txt").write_text("partial\\n")
print("classification detail")
print("generator failure", file=sys.stderr)
raise SystemExit("unclassified candidate")
"""
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      project, _, _, second = make_project_with_reference(root, generator)
      references_path = project / "planning" / "references.json"
      report = update_references.build_impact_report(
        "source",
        second,
        root=project,
        references_path=references_path,
        plan_path=project / "planning" / "plan.json",
        progress_path=project / "planning" / "progress.json",
        generator_commands=(("planning/generate.py",),),
      )

      self.assertFalse(report["valid"])
      self.assertTrue(report["simulation"]["repeatable"])
      error = report["simulation"]["first_run"][0]["error"]
      self.assertIn("classification detail", error)
      self.assertIn("generator failure", error)
      self.assertIn("unclassified candidate", error)
      self.assertIn(
        "artifact generation: failed",
        update_references.render_impact(report, "text"),
      )
      result = update_references.advance_reviewed_reference(
        "source",
        second,
        report["impact_digest"],
        root=project,
        references_path=references_path,
        plan_path=project / "planning" / "plan.json",
        progress_path=project / "planning" / "progress.json",
        generator_commands=(("planning/generate.py",),),
      )

      self.assertFalse(result["artifacts_regenerated"])
      self.assertEqual(second, git(project / "planning" / "source", "rev-parse", "HEAD"))
      self.assertEqual("old\n", (project / "generated.txt").read_text())

  def test_dry_run_simulates_repeatable_generators_in_isolation(self) -> None:
    generator = """\
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
references = json.loads((root / "planning/references.json").read_text())
commit = references["references"]["source"]["commit"]
(root / "generated.txt").write_text(commit + "\\n")
"""
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      project, checkout, first, second = make_project_with_reference(root, generator)
      status_before = git(project, "status", "--porcelain=v1")

      simulation = update_references.simulate_reference_update(
        "source",
        second,
        root=project,
        references_path=project / "planning" / "references.json",
        generator_commands=(("planning/generate.py",),),
      )

      self.assertTrue(simulation["valid"])
      self.assertTrue(simulation["repeatable"])
      self.assertEqual(
        ["generated.txt"],
        [value["path"] for value in simulation["generated_files"]],
      )
      self.assertEqual(status_before, git(project, "status", "--porcelain=v1"))
      self.assertEqual(first, git(checkout, "rev-parse", "HEAD"))
      references = json.loads(
        (project / "planning" / "references.json").read_text(encoding="utf-8")
      )
      self.assertEqual(first, references["references"]["source"]["commit"])

  def test_dry_run_rejects_nonrepeatable_generation(self) -> None:
    generator = """\
from pathlib import Path

target = Path(__file__).resolve().parents[1] / "generated.txt"
value = int(target.read_text().strip() or "0") if target.exists() else 0
target.write_text(str(value + 1) + "\\n")
"""
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      project, _, _, second = make_project_with_reference(root, generator)
      (project / "generated.txt").write_text("0\n", encoding="utf-8")
      git(project, "add", "generated.txt")
      git(project, "commit", "-m", "reset generated value")

      simulation = update_references.simulate_reference_update(
        "source",
        second,
        root=project,
        references_path=project / "planning" / "references.json",
        generator_commands=(("planning/generate.py",),),
      )

      self.assertFalse(simulation["valid"])
      self.assertFalse(simulation["repeatable"])

  def test_inventory_delta_reports_added_removed_and_changed_identities(self) -> None:
    before = {
      "removed": {"fingerprint": "old"},
      "changed": {"fingerprint": "old"},
    }
    after = {
      "added": {"fingerprint": "new"},
      "changed": {"fingerprint": "new"},
    }

    delta = update_references.inventory_delta(before, after)

    self.assertEqual(
      [{"fingerprint": "new", "identity": "added"}],
      delta["added"],
    )
    self.assertEqual(
      [{"fingerprint": "old", "identity": "removed"}],
      delta["removed"],
    )
    self.assertEqual(
      [{
        "from": {"fingerprint": "old"},
        "identity": "changed",
        "to": {"fingerprint": "new"},
      }],
      delta["changed"],
    )

  def test_specification_inventory_reports_every_identity_family(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_specifications_checkout(root)

      impact = update_references.specification_inventory_delta(
        checkout,
        first,
        second,
      )

      self.assertEqual(
        ["example/example.md"],
        [value["identity"] for value in impact["accepted_documents"]["changed"]],
      )
      self.assertEqual(
        ["example/tests/unified/case.json"],
        [value["identity"] for value in impact["fixture_files"]["changed"]],
      )
      self.assertEqual(1, len(impact["cases"]["added"]))
      self.assertEqual(1, len(impact["cases"]["changed"]))
      self.assertEqual(1, len(impact["unified_tests"]["added"]))
      self.assertEqual(1, len(impact["unified_tests"]["changed"]))
      self.assertEqual(first, git(checkout, "rev-parse", "HEAD"))
      worktrees = git(checkout, "worktree", "list", "--porcelain")
      self.assertEqual(1, worktrees.count("worktree "))

  def test_dry_run_reports_candidate_impact_without_moving_pin(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      references_path = write_references(root, first)
      plan_path, progress_path = write_plan(root)
      references_before = references_path.read_bytes()

      report = update_references.analyze_reference(
        "source",
        second,
        root=root,
        references_path=references_path,
        plan_path=plan_path,
        progress_path=progress_path,
      )

      self.assertEqual(first, git(checkout, "rev-parse", "HEAD"))
      self.assertEqual(references_before, references_path.read_bytes())
      self.assertEqual(first, report["from_commit"])
      self.assertEqual(second, report["to_commit"])
      self.assertEqual([second], report["commits"])
      self.assertEqual(
        [{"path": "landmark.py", "status": "M"}],
        report["changed_paths"],
      )
      self.assertEqual(
        [{
          "changed": True,
          "id": "source:landmark",
          "path": "landmark.py",
          "symbol": "Landmark",
        }],
        report["mapped_landmarks"],
      )
      self.assertEqual(
        [{
          "id": "REF-001",
          "mappings": ["source:landmark"],
          "status": "completed",
        }],
        report["affected_activities"],
      )
      self.assertEqual(["REF-001"], report["review_candidates"])
      self.assertTrue(report["valid"])

  def test_dry_run_cli_flags_parse_without_changing_apply_defaults(self) -> None:
    parser = update_references.build_parser()

    dry_run = parser.parse_args([
      "source",
      "a" * 40,
      "--dry-run",
      "--format",
      "json",
    ])
    apply = parser.parse_args(["source", "b" * 40])

    self.assertTrue(dry_run.dry_run)
    self.assertEqual("json", dry_run.format)
    self.assertEqual("relevant", dry_run.show)
    self.assertFalse(dry_run.verify)
    self.assertFalse(apply.dry_run)
    self.assertEqual("text", apply.format)

  def test_advance_updates_checkout_and_plan_pin(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      references_path = write_references(root, first)

      summary = update_references.advance_reference(
        "source",
        second,
        root=root,
        references_path=references_path,
        generator_commands=(),
      )

      self.assertEqual(second, git(checkout, "rev-parse", "HEAD"))
      references = json.loads(references_path.read_text(encoding="utf-8"))
      self.assertEqual(second, references["references"]["source"]["commit"])
      self.assertEqual({"M": 1}, summary)

  def test_advance_rejects_dirty_or_drifted_checkout(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      references_path = write_references(root, first)
      (checkout / "untracked").write_text("dirty", encoding="utf-8")

      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "dirty"):
        update_references.advance_reference(
          "source", second, root=root, references_path=references_path,
          generator_commands=(),
        )

      (checkout / "untracked").unlink()
      git(checkout, "checkout", "--detach", second)
      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "expected"):
        update_references.advance_reference(
          "source", second, root=root, references_path=references_path,
          generator_commands=(),
        )

  def test_advance_requires_fast_forward_by_default(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      references_path = write_references(root, second)
      git(checkout, "checkout", "--detach", first)
      (checkout / "other.py").write_text("value = 1\n", encoding="utf-8")
      git(checkout, "add", "other.py")
      git(checkout, "commit", "-m", "other")
      divergent = git(checkout, "rev-parse", "HEAD")
      git(checkout, "checkout", "--detach", second)

      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "descendant"):
        update_references.advance_reference(
          "source", divergent, root=root, references_path=references_path,
          generator_commands=(),
        )


if __name__ == "__main__":
  unittest.main()
