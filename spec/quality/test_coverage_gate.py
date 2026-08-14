"""Contract tests for the source-coverage ratchet."""

import json
from pathlib import Path
import unittest

from spec.quality import coverage_gate


ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "spec" / "quality" / "coverage-baseline.json"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"


def module_name(path: str) -> str:
  parts = list(Path(path).with_suffix("").parts)
  mongodb = parts.index("mongodb")
  module_parts = parts[mongodb:]

  if module_parts[-1] == "init":
    module_parts.pop()

  return ".".join(module_parts)


class CoverageGateTests(unittest.TestCase):
  def test_production_baseline_excludes_test_only_modules(self):
    classification = json.loads(
      MODULE_CLASSIFICATION.read_text(encoding="utf-8")
    )["modules"]
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    baseline_modules = {
      module_name(path): path
      for path in baseline["files"]
    }

    for name, entry in classification.items():
      with self.subTest(module=name):
        self.assertIn(entry["surface"], ("runtime", "test-only"))

        if entry["surface"] == "runtime":
          self.assertEqual(entry["path"], baseline_modules.get(name))
        else:
          self.assertNotIn(name, baseline_modules)

  def test_applies_platform_adjustments_without_mutating_the_baseline(self):
    baseline = {
      "files": {
        "src/mongodb/a.lua": {"covered": 8, "active": 10},
        "src/mongodb/b.lua": {"covered": 5, "active": 5},
      },
      "platform_adjustments": {
        "linux": {
          "files": {
            "src/mongodb/a.lua": {"covered": -1, "active": -2},
          },
          "total": {"covered": -1, "active": -2},
        },
      },
      "total": {"covered": 13, "active": 15},
    }

    effective = coverage_gate.apply_platform_adjustments(baseline, "linux")

    self.assertEqual(
      {"covered": 7, "active": 8},
      effective["files"]["src/mongodb/a.lua"],
    )
    self.assertEqual(
      {"covered": 5, "active": 5},
      effective["files"]["src/mongodb/b.lua"],
    )
    self.assertEqual({"covered": 12, "active": 13}, effective["total"])
    self.assertEqual(
      {"covered": 8, "active": 10},
      baseline["files"]["src/mongodb/a.lua"],
    )

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
