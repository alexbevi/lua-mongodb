from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v07 import scope


class V07ScopeTests(unittest.TestCase):
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

  def test_generated_scope_closes_client_bulk_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 71,
        "excluded": 0,
        "passed": 71,
        "planned": 0,
        "supported": 71,
      },
      generated["summary"],
    )
    self.assertEqual(71, generated["evidence"]["exact_unified_cases"])
    self.assertEqual({"passed": 53}, generated["suites"]["crud"])
    self.assertEqual(
      {"passed": 9},
      generated["suites"]["retryable-writes"],
    )
    self.assertEqual(
      {"passed": 6},
      generated["suites"]["transactions"],
    )
    self.assertEqual({}, generated["target_version_exclusions"])

  def test_exact_execution_rejects_a_missing_or_failed_target(self) -> None:
    identity = "crud/tests/unified/create-null-ids.json::test[7]"
    cases = {identity: {"status": "passed"}}
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        cases,
        {"ratchets": ratchets, "tests": [], "type": "execution"},
        ratchets,
      )

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        cases,
        self.exact_report(
          identity,
          "failed",
          "unknown unified operation: futureClientBulkWrite",
        ),
        ratchets,
      )

  def test_environment_skip_cannot_replace_exact_evidence(self) -> None:
    identity = "crud/tests/unified/create-null-ids.json::test[7]"
    cases = {identity: {"status": "passed"}}
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        cases,
        self.exact_report(identity, "environment_skipped"),
        ratchets,
      )

  def test_exact_execution_allows_only_declared_macos_timing_skip(self) -> None:
    identity = "client-side-operations-timeout/tests/bulkWrite.json::test[1]"
    cases = {identity: {"status": "passed"}}
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}
    report = self.exact_report(identity, "environment_skipped")

    self.assertEqual(
      {"macos_timing_skipped": 1, "passed": 0, "required": 1},
      scope.validate_execution(
        cases,
        report,
        ratchets,
        allow_macos_ci_timing_skips=True,
      ),
    )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(cases, report, ratchets)

    unrelated = "crud/tests/unified/create-null-ids.json::test[7]"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(unrelated)):
      scope.validate_execution(
        {unrelated: {"status": "passed"}},
        self.exact_report(unrelated, "environment_skipped"),
        ratchets,
        allow_macos_ci_timing_skips=True,
      )

  def test_completed_owner_cannot_hide_a_deferred_case(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    activities = scope.load_activities()
    identity, owner = next(
      (identity, case["activity"])
      for identity, case in cases.items()
      if case.get("activity") != "REL-055"
    )
    cases[identity]["status"] = "deferred_unsupported"
    activities[owner]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)

  def test_exact_executor_environment_is_required(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    activities = scope.load_activities()
    executors = copy.deepcopy(scope.load_executors())
    identity = next(iter(cases))
    executors[identity]["environment"] = "live-mongodb"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities, executors)


if __name__ == "__main__":
  unittest.main()
