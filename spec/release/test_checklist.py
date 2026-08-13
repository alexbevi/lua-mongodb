"""Contract tests for the production-core v1 release checklist."""

import unittest

from spec.release import checklist


class ReleaseChecklistTests(unittest.TestCase):
  def test_checked_in_release_is_ready(self):
    report = checklist.generate()

    self.assertTrue(report["ready"])
    self.assertEqual("0.1.0", report["release"]["version"])
    conformance = report["gates"]["conformance"]

    self.assertEqual(0, conformance["applicable_gaps"])
    self.assertEqual(5524, conformance["classified_cases"])
    self.assertGreaterEqual(conformance["passed_cases"], 3570)
    self.assertLessEqual(conformance["post_v1_exclusions"], 1954)
    self.assertEqual(
      conformance["classified_cases"],
      conformance["passed_cases"] + conformance["post_v1_exclusions"],
    )
    self.assertEqual(
      {"profiles": 30, "rows": 6},
      report["gates"]["compatibility"],
    )
    self.assertEqual(
      {
        "cleanup": ["REL-042", "REL-043"],
        "packaging": ["REL-007"],
        "security": ["REL-008"],
      },
      report["gates"]["completed_audits"],
    )
    self.assertEqual(
      [
        "fast-compatibility-smoke",
        "fast-portable",
        "full-compatibility",
        "full-linux-aggregate",
        "full-linux-quality",
        "full-linux-unified",
        "full-macos",
      ],
      report["gates"]["ci"],
    )


if __name__ == "__main__":
  unittest.main()
