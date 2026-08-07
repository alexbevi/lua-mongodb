"""Contract tests for the source-coverage ratchet."""

import unittest

from spec.quality import coverage_gate


class CoverageGateTests(unittest.TestCase):
  def test_rejects_a_per_file_or_total_coverage_regression(self):
    baseline = {
      "files": {
        "src/mongodb/a.lua": {"covered": 8, "active": 10},
        "src/mongodb/b.lua": {"covered": 5, "active": 5},
      },
      "total": {"covered": 13, "active": 15},
    }
    measured = {
      "files": {
        "src/mongodb/a.lua": {"covered": 7, "active": 10},
        "src/mongodb/b.lua": {"covered": 5, "active": 5},
      },
      "total": {"covered": 12, "active": 15},
    }

    violations = coverage_gate.regressions(measured, baseline)

    self.assertEqual(
      [
        "src/mongodb/a.lua: line coverage regressed from 8/10 to 7/10",
        "total: line coverage regressed from 13/15 to 12/15",
      ],
      violations,
    )


if __name__ == "__main__":
  unittest.main()
