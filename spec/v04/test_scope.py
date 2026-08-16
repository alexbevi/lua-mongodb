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
    self.assertEqual(694, generated["summary"]["passed"])
    self.assertEqual(157, generated["summary"]["planned"])
    self.assertEqual(47, generated["summary"]["excluded"])
    self.assertEqual(851, generated["summary"]["supported"])
    self.assertEqual(
      {
        "ADV-005": 1,
        "CFG-004": 1,
        "CMAP-002": 5,
        "CMAP-003": 8,
        "CMAP-004": 3,
        "DNS-001": 4,
        "IDX-001": 3,
        "IDX-002": 4,
        "IDX-003": 3,
        "IDX-004": 1,
        "IDX-005": 1,
        "IDX-006": 5,
        "SDAM-004": 1,
        "SDAM-005": 6,
        "SDAM-006": 7,
        "SDAM-007": 1,
        "SES-005": 15,
        "SES-006": 7,
        "SES-007": 5,
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
    identity = next(
      identity for identity, case in cases.items()
      if case.get("activity") == "SES-005"
    )
    activities["SES-005"]["status"] = "completed"

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, activities)


if __name__ == "__main__":
  unittest.main()
