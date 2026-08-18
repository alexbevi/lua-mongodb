"""Contract tests for the legacy APIs v0.6 release checklist."""

import unittest

from spec.release import checklist


class ReleaseChecklistTests(unittest.TestCase):
  def test_checked_in_release_is_ready(self):
    report = checklist.generate()

    self.assertTrue(report["ready"])
    self.assertEqual("legacy-api-release-checklist", report["type"])
    self.assertEqual("0.6.0", report["release"]["version"])
    conformance = report["gates"]["conformance"]

    self.assertEqual(0, conformance["applicable_gaps"])
    self.assertEqual(5524, conformance["classified_cases"])
    self.assertGreaterEqual(conformance["passed_cases"], 4082)
    self.assertLessEqual(conformance["post_v1_exclusions"], 1442)
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
        "excluded_cases": 45,
        "exact_unified_cases": 357,
        "passed_cases": 853,
        "read_write_concern_passed": 48,
        "target_version_exclusions": 6,
      },
      report["gates"]["v0_4_conformance"],
    )
    self.assertEqual(
      {
        "classified_cases": 189,
        "excluded_cases": 19,
        "exact_unified_cases": 170,
        "passed_cases": 170,
        "target_version_exclusions": 19,
      },
      report["gates"]["v0_5_conformance"],
    )
    self.assertEqual(
      {
        "classified_cases": 176,
        "excluded_cases": 95,
        "exact_unified_cases": 81,
        "passed_cases": 81,
        "reference_behavior_exclusions": 3,
        "target_version_exclusions": 92,
      },
      report["gates"]["v0_6_conformance"],
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
        "ADV-005",
        "CON-002",
        "SES-003",
        "SES-004",
        "SES-005",
        "SES-008",
        "SES-006",
        "SES-007",
        "IDX-001",
        "IDX-002",
        "IDX-003",
        "IDX-004",
        "IDX-005",
        "IDX-006",
        "CI-005",
        "SDAM-004",
        "SDAM-005",
        "SDAM-006",
        "SDAM-008",
        "SDAM-007",
        "CFG-004",
        "CMAP-002",
        "CMAP-003",
        "CMAP-004",
        "DNS-001",
        "TXN-003",
        "TXN-004",
        "TXN-005",
        "TXN-006",
        "TXN-007",
        "CMP-002",
        "REL-049",
      ],
      report["gates"]["completed_v0_4_gates"],
    )
    self.assertEqual(
      [
        "ADV-001",
        *[f"CS-{index:03d}" for index in range(1, 13)],
        "REL-051",
      ],
      report["gates"]["completed_v0_5_gates"],
    )
    self.assertEqual(
      [
        "ADV-011",
        *[f"LEG-{index:03d}" for index in range(1, 14)],
        "REL-053",
      ],
      report["gates"]["completed_v0_6_gates"],
    )
    self.assertEqual(
      [
        "fast-compatibility-smoke",
        "fast-portable",
        "full-compatibility",
        "full-linux-aggregate",
        "full-linux-quality",
        "full-linux-unified",
        "full-linux-version-branches",
        "full-macos-aggregate",
        "full-macos-platform",
        "full-macos-unified",
        "full-macos-version-branches",
      ],
      report["gates"]["ci"],
    )


if __name__ == "__main__":
  unittest.main()
