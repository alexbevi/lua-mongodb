"""Contract tests for the wire compression v0.8 release checklist."""

import unittest

from spec.release import checklist


class ReleaseChecklistTests(unittest.TestCase):
  def test_checked_in_release_is_ready(self):
    report = checklist.generate()

    self.assertTrue(report["ready"])
    self.assertEqual("wire-compression-release-checklist", report["type"])
    self.assertEqual("0.8.0", report["release"]["version"])
    conformance = report["gates"]["conformance"]

    self.assertEqual(0, conformance["applicable_gaps"])
    self.assertEqual(5524, conformance["classified_cases"])
    self.assertGreaterEqual(conformance["passed_cases"], 4153)
    self.assertLessEqual(conformance["post_v1_exclusions"], 1371)
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
        "excluded_cases": 39,
        "exact_unified_cases": 363,
        "passed_cases": 859,
        "read_write_concern_passed": 48,
        "target_version_exclusions": 6,
      },
      report["gates"]["v0_4_conformance"],
    )
    self.assertEqual(
      {
        "classified_cases": 195,
        "excluded_cases": 19,
        "exact_unified_cases": 176,
        "passed_cases": 176,
        "target_version_exclusions": 19,
      },
      report["gates"]["v0_5_conformance"],
    )
    self.assertEqual(
      {
        "classified_cases": 179,
        "excluded_cases": 95,
        "exact_unified_cases": 84,
        "passed_cases": 84,
        "reference_behavior_exclusions": 3,
        "target_version_exclusions": 92,
      },
      report["gates"]["v0_6_conformance"],
    )
    self.assertEqual(
      {
        "classified_cases": 71,
        "excluded_cases": 0,
        "exact_unified_cases": 71,
        "passed_cases": 71,
        "target_version_exclusions": 0,
      },
      report["gates"]["v0_7_conformance"],
    )
    self.assertEqual(
      {
        "classified_requirements": 16,
        "configuration_cases": 5,
        "passed_requirements": 16,
        "prose_requirements": 11,
      },
      report["gates"]["v0_8_conformance"],
    )
    self.assertEqual(
      {
        "classified_requirements": 113,
        "csot_cases": 25,
        "exact_unified_cases": 98,
        "gridfs_cases": 39,
        "passed_requirements": 113,
        "prose_requirements": 15,
        "retryable_read_cases": 34,
      },
      report["gates"]["v0_9_conformance"],
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
        "ADV-007",
        "CBW-001",
        "CBW-002",
        "CBW-003",
        "CBW-004",
        "CBW-005",
        "CBW-006",
        "CBW-013",
        "CBW-014",
        "CBW-015",
        "CBW-016",
        "CBW-007",
        "CBW-017",
        "CBW-018",
        "CBW-008",
        "CBW-009",
        "CBW-010",
        "CBW-011",
        "CBW-012",
        "REL-055",
      ],
      report["gates"]["completed_v0_7_gates"],
    )
    self.assertEqual(
      [
        "ADV-004",
        *[f"WIRE-{index:03d}" for index in range(2, 10)],
        "CON-008",
      ],
      report["gates"]["completed_v0_8_gates"],
    )
    self.assertEqual(
      [
        "ADV-002",
        *[f"GFS-{index:03d}" for index in range(1, 15)],
      ],
      report["gates"]["completed_v0_9_gates"],
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
