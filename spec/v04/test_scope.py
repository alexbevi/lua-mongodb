from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import unittest

from spec.v04 import scope


ROOT = Path(__file__).resolve().parents[2]


class V04ScopeTests(unittest.TestCase):
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
    identity = "sessions/tests/snapshot-sessions.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    report = self.exact_report(
      identity,
      "environment_skipped",
      "sharded environment unavailable",
    )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        cases,
        report,
        {"classified": 1, "passed": 1, "runnable": 1},
      )

  def test_exact_execution_rejects_unknown_operation_failure(self) -> None:
    identity = "transactions/tests/unified/pin-mongos.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
    }
    report = self.exact_report(
      identity,
      "failed",
      "unknown unified operation: futureWrite",
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
    identity = "index-management/tests/createSearchIndex.json::test[1]"
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

  def test_exact_execution_accepts_every_passing_target_row(self) -> None:
    identity = "sessions/tests/snapshot-sessions.json::test[1]"
    cases = {
      identity: {
        "runner": "spec/unified/execute.lua",
        "status": "passed",
      },
      "sessions/tests/legacy.json::test[1]": {
        "runner": "spec/support/session_runner.lua",
        "status": "passed",
      },
    }
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}

    self.assertEqual(
      {"passed": 1, "required": 1},
      scope.validate_execution(
        cases,
        self.exact_report(identity),
        ratchets,
      ),
    )

  def test_generated_scope_defines_the_requested_parity_boundary(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(898, generated["summary"]["classified"])
    self.assertEqual(851, generated["summary"]["passed"])
    self.assertEqual(0, generated["summary"]["planned"])
    self.assertEqual(47, generated["summary"]["excluded"])
    self.assertEqual(851, generated["summary"]["supported"])
    self.assertEqual(2, generated["schema_version"])
    self.assertEqual(scope.RATCHETS, generated["ratchets"])
    self.assertEqual(
      {"exact_unified_cases": 355, "static_passing_cases": 496},
      generated["evidence"],
    )
    self.assertEqual({}, generated["planned_by_activity"])
    self.assertEqual(
      {"passed": 48, "excluded": 1},
      generated["suites"]["read-write-concern"],
    )
    self.assertEqual(
      {
        "read-write-concern/tests/operation/"
        "default-write-concern-3.4.json::test[4]": (
          "legacy mapReduce concern behavior requires MongoDB 3.4, below "
          "the v0.4 MongoDB 7.0 compatibility floor"
        ),
      },
      generated["target_version_exclusions"],
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
