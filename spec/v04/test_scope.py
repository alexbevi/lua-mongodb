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
    self.assertEqual(754, generated["summary"]["passed"])
    self.assertEqual(97, generated["summary"]["planned"])
    self.assertEqual(47, generated["summary"]["excluded"])
    self.assertEqual(851, generated["summary"]["supported"])
    self.assertEqual(
      {
        "CFG-004": 1,
        "CMAP-002": 5,
        "CMAP-003": 8,
        "CMAP-004": 3,
        "DNS-001": 4,
        "TXN-003": 9,
        "TXN-004": 7,
        "TXN-005": 4,
        "TXN-006": 20,
        "TXN-007": 36,
      },
      generated["planned_by_activity"],
    )
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
      if case.get("status") == "deferred_unsupported"
        and case.get("activity") in activities
        and activities[case["activity"]].get("track") == "v0-4-sharded-parity"
    )
    activities[owner]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)


if __name__ == "__main__":
  unittest.main()
