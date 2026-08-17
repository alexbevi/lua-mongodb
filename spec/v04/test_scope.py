from __future__ import annotations

import copy
import json
from pathlib import Path
import re
import unittest

from spec.v04 import scope


ROOT = Path(__file__).resolve().parents[2]


class V04ScopeTests(unittest.TestCase):
  def test_generated_scope_defines_the_requested_parity_boundary(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(898, generated["summary"]["classified"])
    self.assertEqual(851, generated["summary"]["passed"])
    self.assertEqual(0, generated["summary"]["planned"])
    self.assertEqual(47, generated["summary"]["excluded"])
    self.assertEqual(851, generated["summary"]["supported"])
    self.assertEqual({}, generated["planned_by_activity"])
    self.assertEqual(
      {"passed": 48, "excluded": 1},
      generated["suites"]["read-write-concern"],
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
