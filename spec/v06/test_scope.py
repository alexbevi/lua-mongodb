from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v06 import scope


class V06ScopeTests(unittest.TestCase):
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

  def test_generated_scope_closes_the_legacy_api_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 179,
        "excluded": 95,
        "passed": 84,
        "planned": 0,
        "supported": 84,
      },
      generated["summary"],
    )
    self.assertEqual(84, generated["evidence"]["exact_unified_cases"])
    self.assertEqual(92, len(generated["target_version_exclusions"]))
    self.assertEqual(3, len(generated["reference_behavior_exclusions"]))
    self.assertEqual(
      {"reference-behavior": 3, "target-version": 92},
      generated["excluded_by_reason"],
    )
    self.assertEqual(
      {"excluded": 72, "passed": 14},
      generated["suites"]["crud"],
    )
    self.assertEqual(
      {"excluded": 3, "passed": 43},
      generated["suites"]["client-side-operations-timeout"],
    )

  def test_exact_execution_rejects_a_missing_or_failed_target(self) -> None:
    identity = "crud/tests/unified/count.json::test[1]"
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
          "unknown unified operation: futureCount",
        ),
        ratchets,
      )

  def test_exact_execution_accepts_only_named_macos_timing_skips(self) -> None:
    identity = (
      "client-side-operations-timeout/tests/"
      "tailable-awaitData.json::test[9]"
    )
    cases = {identity: {"status": "passed"}}
    ratchets = {"classified": 1, "passed": 1, "runnable": 1}
    report = self.exact_report(identity, "environment_skipped")

    self.assertEqual(
      {
        "client-side-operations-timeout/tests/"
        "tailable-awaitData.json::test[9]",
        "client-side-operations-timeout/tests/"
        "tailable-awaitData.json::test[10]",
        "client-side-operations-timeout/tests/"
        "tailable-awaitData.json::test[12]",
        "client-side-operations-timeout/tests/"
        "tailable-non-awaitData.json::test[3]",
      },
      scope.MACOS_CI_TIMING_SKIPS,
    )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(cases, report, ratchets)

    self.assertEqual(
      {"macos_timing_skipped": 1, "passed": 0, "required": 1},
      scope.validate_execution(
        cases,
        report,
        ratchets,
        allow_macos_ci_timing_skips=True,
      ),
    )

    unrelated = "client-side-operations-timeout/tests/count.json::test[1]"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(unrelated)):
      scope.validate_execution(
        {unrelated: {"status": "passed"}},
        self.exact_report(unrelated, "environment_skipped"),
        ratchets,
        allow_macos_ci_timing_skips=True,
      )

  def test_exclusion_identity_status_and_reason_are_exact(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    activities = scope.load_activities()
    identity = next(iter(scope.TARGET_VERSION_EXCLUSIONS))
    cases[identity]["reason"] = "generic old server exclusion"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)

    cases = copy.deepcopy(scope.load_cases())
    cases[identity]["status"] = "deferred_unsupported"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)

  def test_completed_owner_cannot_hide_a_deferred_case(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    activities = scope.load_activities()
    identity, owner = next(
      (identity, case["activity"])
      for identity, case in cases.items()
      if case.get("status") == "passed"
    )
    cases[identity]["status"] = "deferred_unsupported"
    activities[owner]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)


if __name__ == "__main__":
  unittest.main()
