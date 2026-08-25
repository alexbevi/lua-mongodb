from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v09 import scope


class V09ScopeTests(unittest.TestCase):
  def exact_report(
    self,
    identity: str | None = None,
    status: str = "passed",
    error: str | None = None,
  ) -> dict[str, object]:
    rows = [
      {"id": case_identity, "status": "passed"}
      for case_identity in sorted(scope.MACHINE_CASES)
    ]
    if identity is not None:
      row = next(value for value in rows if value["id"] == identity)
      row["status"] = status
      if error is not None:
        row["error"] = error
    return {
      "ratchets": scope.load_capability_ratchets(),
      "tests": rows,
      "type": "execution",
    }

  def test_generated_scope_closes_gridfs_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 113,
        "passed": 113,
        "planned": 0,
        "supported": 113,
      },
      generated["summary"],
    )
    self.assertEqual(
      {
        "csot_cases": 25,
        "gridfs_cases": 39,
        "prose_requirements": 15,
        "retryable_read_cases": 34,
      },
      generated["evidence"],
    )
    self.assertEqual(
      {
        "client-side-operations-timeout": {"passed": 25},
        "gridfs": {"passed": 54},
        "retryable-reads": {"passed": 34},
      },
      generated["suites"],
    )

  def test_every_normative_behavior_has_exact_passing_evidence(self) -> None:
    generated = scope.generate()

    self.assertEqual(set(scope.PROSE_REQUIREMENTS), set(generated["prose_requirements"]))
    self.assertEqual(scope.MACHINE_CASES, set(generated["machine_cases"]))

  def test_exact_execution_rejects_a_missing_or_failed_target(self) -> None:
    cases = scope.load_cases()
    ratchets = scope.load_capability_ratchets()
    identity = "gridfs/tests/download.json::test[1]"
    missing = self.exact_report()
    missing["tests"] = [
      row for row in missing["tests"] if row["id"] != identity
    ]

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(cases, missing, ratchets)

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        cases,
        self.exact_report(
          identity,
          "failed",
          "unknown unified operation: futureGridFSOperation",
        ),
        ratchets,
      )

  def test_environment_skip_cannot_replace_exact_evidence(self) -> None:
    identity = "gridfs/tests/download.json::test[1]"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        scope.load_cases(),
        self.exact_report(identity, "environment_skipped"),
        scope.load_capability_ratchets(),
      )

  def test_exact_execution_allows_only_declared_macos_timing_skip(self) -> None:
    identity = next(iter(scope.MACOS_CI_TIMING_SKIPS))
    report = self.exact_report(identity, "environment_skipped")

    self.assertEqual(
      {"macos_timing_skipped": 1, "passed": 97, "required": 98},
      scope.validate_execution(
        scope.load_cases(),
        report,
        scope.load_capability_ratchets(),
        allow_macos_ci_timing_skips=True,
      ),
    )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        scope.load_cases(),
        report,
        scope.load_capability_ratchets(),
      )

    unrelated = "gridfs/tests/download.json::test[1]"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(unrelated)):
      scope.validate_execution(
        scope.load_cases(),
        self.exact_report(unrelated, "environment_skipped"),
        scope.load_capability_ratchets(),
        allow_macos_ci_timing_skips=True,
      )

  def test_completed_owner_cannot_hide_non_passing_evidence(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    requirements = scope.load_requirements()
    activities = scope.load_activities()
    identity = "gridfs/tests/download.json::test[1]"
    cases[identity]["status"] = "deferred_unsupported"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, requirements, activities)

  def test_exact_executor_and_prose_evidence_are_required(self) -> None:
    cases = scope.load_cases()
    requirements = copy.deepcopy(scope.load_requirements())
    activities = scope.load_activities()
    executors = copy.deepcopy(scope.load_executors())
    machine_identity = "gridfs/tests/download.json::test[1]"
    prose_identity = "gridfs/gridfs-spec.md::download-streams"

    executors[machine_identity]["environment"] = "live-mongodb"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(machine_identity)):
      scope.classify(cases, requirements, activities, executors)

    requirements[prose_identity]["runner"] = "spec/unit/future_gridfs_spec.lua"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(prose_identity)):
      scope.classify(cases, requirements, activities)


if __name__ == "__main__":
  unittest.main()
