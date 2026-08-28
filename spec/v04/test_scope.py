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

  def test_exact_execution_combines_mutually_exclusive_server_versions(
    self,
  ) -> None:
    identity = "index-management/tests/index-rawdata.json::test[2]"
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
      {"passed": 1, "required": 1},
      scope.validate_execution(
        cases,
        [
          self.exact_report(identity, "environment_skipped"),
          supplemental,
        ],
        ratchets,
      ),
    )

  def test_exact_execution_does_not_mask_a_failed_version(self) -> None:
    identity = "transactions/tests/unified/pin-mongos.json::test[1]"
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
            "unknown unified operation: futureWrite",
          ),
        ],
        ratchets,
      )

  def test_generated_scope_defines_the_requested_parity_boundary(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(898, generated["summary"]["classified"])
    self.assertEqual(883, generated["summary"]["passed"])
    self.assertEqual(0, generated["summary"]["planned"])
    self.assertEqual(15, generated["summary"]["excluded"])
    self.assertEqual(883, generated["summary"]["supported"])
    self.assertEqual(2, generated["schema_version"])
    self.assertEqual(scope.RATCHETS, generated["ratchets"])
    self.assertEqual(
      {"exact_unified_cases": 376, "static_passing_cases": 507},
      generated["evidence"],
    )
    self.assertEqual({}, generated["planned_by_activity"])
    self.assertEqual(
      {"passed": 48, "excluded": 1},
      generated["suites"]["read-write-concern"],
    )
    self.assertEqual(6, len(generated["target_version_exclusions"]))
    self.assertEqual(
      scope.TARGET_VERSION_EXCLUSIONS,
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
