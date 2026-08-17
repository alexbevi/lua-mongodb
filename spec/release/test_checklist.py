"""Contract tests for the DNS seedlist v0.2 release checklist."""

import unittest

from spec.release import checklist


class ReleaseChecklistTests(unittest.TestCase):
  def test_checked_in_release_is_ready(self):
    report = checklist.generate()

    self.assertTrue(report["ready"])
    self.assertEqual("authentication-release-checklist", report["type"])
    self.assertEqual("0.3.0", report["release"]["version"])
    conformance = report["gates"]["conformance"]

    self.assertEqual(0, conformance["applicable_gaps"])
    self.assertEqual(5524, conformance["classified_cases"])
    self.assertGreaterEqual(conformance["passed_cases"], 3610)
    self.assertLessEqual(conformance["post_v1_exclusions"], 1914)
    self.assertEqual(
      conformance["classified_cases"],
      conformance["passed_cases"] + conformance["post_v1_exclusions"],
    )
    self.assertEqual(
      {"profiles": 45, "rows": 9},
      report["gates"]["compatibility"],
    )
    self.assertEqual(
      {
        "classified_cases": 898,
        "excluded_cases": 47,
        "exact_unified_cases": 355,
        "passed_cases": 851,
        "read_write_concern_passed": 48,
        "target_version_exclusions": 1,
      },
      report["gates"]["v0_4_conformance"],
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
      ["ADV-003", "ADV-013", "ADV-014", "ADV-015"],
      report["gates"]["completed_release_additions"],
    )
    self.assertEqual(
      [f"AUTH-{index:03d}" for index in range(1, 31) if index != 19],
      report["gates"]["completed_authentication_gates"],
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
