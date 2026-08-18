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
        "classified": 176,
        "excluded": 95,
        "passed": 81,
        "planned": 0,
        "supported": 81,
      },
      generated["summary"],
    )
    self.assertEqual(81, generated["evidence"]["exact_unified_cases"])
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
      {"excluded": 3, "passed": 40},
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
