from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v10 import scope


class V10ScopeTests(unittest.TestCase):
  def exact_report(
    self,
    identity: str | None = None,
    status: str = "passed",
    error: str | None = None,
  ) -> dict[str, object]:
    rows = [
      {"id": case_identity, "status": "passed"}
      for case_identity in scope.generate()["exact_unified_cases"]
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

  def test_generated_scope_closes_load_balancing(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 1042,
        "excluded": 18,
        "passed": 777,
        "planned": 245,
        "supported": 777,
        "unsupported": 2,
      },
      generated["summary"],
    )
    self.assertEqual(
      {
        "dedicated_cases": 40,
        "exact_unified_cases": 738,
        "run_on_branches": 1000,
        "terminal_unsupported": 2,
      },
      generated["evidence"],
    )

  def test_every_load_balanced_identity_is_classified(self) -> None:
    generated = scope.generate()

    self.assertEqual(
      {
        identity
        for identity, case in scope.load_cases().items()
        if case["suite"] == "load-balancers"
      },
      set(generated["dedicated_cases"]),
    )
    self.assertEqual(
      {
        identity
        for identity, capability in scope.load_capabilities().items()
        if scope._is_load_balanced_branch(capability)
      },
      set(generated["run_on_branches"]),
    )

  def test_exact_execution_rejects_missing_failed_and_skipped_targets(self) -> None:
    identity = sorted(scope.CLOSURE_EXECUTORS)[0]
    missing = self.exact_report()
    missing["tests"] = [
      row for row in missing["tests"] if row["id"] != identity
    ]

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(missing, scope.load_capability_ratchets())

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        self.exact_report(
          identity,
          "failed",
          "unknown unified operation: futureOperation",
        ),
        scope.load_capability_ratchets(),
      )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        self.exact_report(identity, "environment_skipped"),
        scope.load_capability_ratchets(),
      )

  def test_optional_branch_requires_an_incomplete_out_of_track_owner(self) -> None:
    activities = copy.deepcopy(scope.load_activities())
    activities["ADV-010"]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, "optional-suite owner"):
      scope.classify(
        scope.load_cases(),
        scope.load_requirements(),
        scope.load_capabilities(),
        scope.load_executors(),
        activities,
      )

  def test_closure_cases_use_the_load_balanced_executor(self) -> None:
    generated = scope.generate()
    executors = scope.load_executors()

    self.assertTrue(scope.CLOSURE_EXECUTORS <= set(generated["exact_unified_cases"]))

    for identity in scope.CLOSURE_EXECUTORS:
      self.assertEqual("CON-010", executors[identity]["activity"])
      self.assertEqual("live-load-balanced", executors[identity]["environment"])

  def test_upstream_skip_and_terminal_unsupported_are_exact(self) -> None:
    generated = scope.generate()
    skipped = generated["dedicated_cases"][scope.UPSTREAM_SKIP]

    self.assertEqual("excluded_scope", skipped["status"])
    self.assertIn("skipReason", skipped["reason"])
    self.assertEqual(
      scope.TERMINAL_UNSUPPORTED,
      {
        identity: evidence["activity"]
        for identity, evidence in generated["terminal_unsupported"].items()
      },
    )


if __name__ == "__main__":
  unittest.main()
