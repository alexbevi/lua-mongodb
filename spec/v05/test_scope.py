from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import unittest

from spec.v05 import scope


ROOT = Path(__file__).resolve().parents[2]


class V05ScopeTests(unittest.TestCase):
  def exact_report(
    self,
    identity: str,
    status: str = "passed",
    error: str | None = None,
  ) -> dict[str, object]:
    row = {"id": identity, "status": status}
    if error is not None:
      row["error"] = error
    return {
      "ratchets": {"classified": 1, "passed": 1, "runnable": 1},
      "tests": [row],
      "type": "execution",
    }

  def test_exact_execution_rejects_environment_skipped_target(self) -> None:
    identity = "change-streams/tests/unified/change-streams.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    report = self.exact_report(
      identity,
      "environment_skipped",
      "replica-set environment unavailable",
    )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        cases,
        report,
        {"classified": 1, "passed": 1, "runnable": 1},
      )

  def test_exact_execution_allows_only_declared_macos_timing_skips(
    self,
  ) -> None:
    identity = next(iter(scope.MACOS_CI_TIMING_SKIPS))
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    self.assertEqual(
      {"macos_timing_skipped": 1, "passed": 0, "required": 1},
      scope.validate_execution(
        cases,
        self.exact_report(identity, "environment_skipped"),
        ratchets,
        allow_macos_ci_timing_skips=True,
      ),
    )

    unrelated = "change-streams/tests/unified/change-streams.json::test[1]"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(unrelated)):
      scope.validate_execution(
        {
          unrelated: {
            "runner": "spec/unified/execute.lua",
            "status": "passed",
          },
        },
        self.exact_report(unrelated, "environment_skipped"),
        ratchets,
        allow_macos_ci_timing_skips=True,
      )

  def test_exact_execution_rejects_unknown_operation_failure(self) -> None:
    identity = "change-streams/tests/unified/change-streams.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    report = self.exact_report(
      identity,
      "failed",
      "unknown unified operation: futureWatch",
    )

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        cases,
        report,
        {"classified": 1, "passed": 1, "runnable": 1},
      )

  def test_exact_execution_rejects_missing_rows_and_ratchet_reductions(
    self,
  ) -> None:
    identity = "change-streams/tests/unified/change-streams.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        cases,
        {"ratchets": ratchets, "tests": [], "type": "execution"},
        ratchets,
      )

    report = self.exact_report(identity)
    report["ratchets"] = {"classified": 1, "passed": 0, "runnable": 1}
    with self.assertRaisesRegex(scope.ScopeError, "ratchets"):
      scope.validate_execution(cases, report, ratchets)

  def test_exact_execution_combines_environment_reports(self) -> None:
    identity = "change-streams/tests/unified/change-streams.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}
    supplemental = self.exact_report(identity)
    supplemental["ratchets"] = {
      "classified": 0,
      "passed": 0,
      "runnable": 0,
    }

    self.assertEqual(
      {"macos_timing_skipped": 0, "passed": 1, "required": 1},
      scope.validate_execution(
        cases,
        [
          self.exact_report(identity, "environment_skipped"),
          supplemental,
        ],
        ratchets,
      ),
    )

  def test_exact_execution_does_not_mask_a_failed_environment(self) -> None:
    identity = "change-streams/tests/unified/change-streams.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        cases,
        [
          self.exact_report(identity),
          self.exact_report(
            identity,
            "failed",
            "unknown unified operation: futureWatch",
          ),
        ],
        ratchets,
      )

  def test_generated_scope_closes_the_change_stream_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(189, generated["summary"]["classified"])
    self.assertEqual(170, generated["summary"]["passed"])
    self.assertEqual(0, generated["summary"]["planned"])
    self.assertEqual(19, generated["summary"]["excluded"])
    self.assertEqual(170, generated["evidence"]["exact_unified_cases"])
    self.assertEqual(170, generated["summary"]["supported"])
    self.assertEqual({}, generated["planned_by_activity"])
    self.assertEqual({"REL-053": 19}, generated["excluded_by_activity"])
    self.assertEqual({"passed": 70, "excluded": 19}, generated["suites"]["change-streams"])
    self.assertEqual({"passed": 43}, generated["suites"]["client-side-operations-timeout"])
    self.assertEqual({"passed": 57}, generated["suites"]["retryable-reads"])
    self.assertEqual(19, len(generated["target_version_exclusions"]))
    self.assertEqual(scope.RATCHETS, generated["ratchets"])

  def test_target_selector_excludes_unrelated_retryable_reads(self) -> None:
    cases = scope.load_cases()

    self.assertEqual(189, len(cases))
    self.assertNotIn(
      "retryable-reads/tests/unified/find-serverErrors.json::test[1]",
      cases,
    )
    self.assertIn(
      "retryable-reads/tests/unified/"
      "changeStreams-db.coll.watch-serverErrors.json::test[1]",
      cases,
    )

  def test_completed_owner_cannot_hide_a_planned_case(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    activities = scope.load_activities()
    identity, owner = next(
      (identity, case["activity"])
      for identity, case in cases.items()
      if case.get("status") == "passed"
        and case.get("activity") in scope.TARGET_OWNERS
    )
    cases[identity]["status"] = "deferred_unsupported"
    activities[owner]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)


if __name__ == "__main__":
  unittest.main()
