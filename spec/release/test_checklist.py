"""Contract tests for the GSSAPI v0.10.2 release checklist."""

import unittest

from spec.release import checklist


class ReleaseChecklistTests(unittest.TestCase):
  def test_checked_in_release_is_ready(self):
    report = checklist.generate()

    self.assertTrue(report["ready"])
    self.assertEqual("gssapi-release-checklist", report["type"])
    self.assertEqual("0.10.2", report["release"]["version"])
    self.assertEqual(
      {
        "activities": ["CSOT-001", "BSON-010"],
        "bson_objectid_requirements": 1,
        "csot_cases": 3,
        "passed_requirements": 4,
      },
      report["gates"]["maintenance"],
    )
    conformance = report["gates"]["conformance"]

    self.assertEqual(0, conformance["applicable_gaps"])
    self.assertEqual(5524, conformance["classified_cases"])
    self.assertGreaterEqual(conformance["passed_cases"], 4153)
    self.assertLessEqual(conformance["additional_exclusions"], 1371)
    self.assertEqual(15, conformance["unsupported_cases"])
    self.assertEqual(
      conformance["classified_cases"],
      conformance["passed_cases"]
      + conformance["additional_exclusions"]
      + conformance["unsupported_cases"],
    )
    self.assertEqual(
      {"profiles": 45, "rows": 9},
      report["gates"]["compatibility"],
    )
    self.assertEqual(
      {
        "classified_cases": 898,
        "excluded_cases": 25,
        "exact_unified_cases": 366,
        "passed_cases": 873,
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
        "classified_requirements": 1042,
        "dedicated_cases": 40,
        "exact_unified_cases": 738,
        "excluded_requirements": 18,
        "optional_requirements": 245,
        "passed_requirements": 777,
        "run_on_branches": 1000,
        "unsupported_requirements": 2,
      },
      report["gates"]["v0_10_conformance"],
    )
    self.assertEqual(
      {
        "classified_requirements": 21,
        "configuration_cases": 11,
        "passed_requirements": 21,
        "prose_requirements": 10,
        "provider_claims": [
          {
            "lua": "5.4",
            "operating_system": "Ubuntu 24.04",
            "provider": "packaged system GSSAPI adapter",
            "required_environment": "ubuntu-24.04-lua-5.4-gssapi-live",
          },
        ],
      },
      report["gates"]["v0_10_2_conformance"],
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
        "CON-009",
      ],
      report["gates"]["completed_v0_9_gates"],
    )
    self.assertEqual(
      [
        *checklist.V10_CORE_GATES,
        *checklist.V10_TERMINAL_GATES,
        checklist.V10_CONFORMANCE_ACTIVITY,
      ],
      report["gates"]["completed_v0_10_gates"],
    )
    self.assertEqual(
      [
        "AUTH-019",
        *[f"AUTH-{index:03d}" for index in range(31, 41)],
        "CON-013",
      ],
      report["gates"]["completed_v0_10_2_gates"],
    )
    self.assertEqual(
      [
        "fast-compatibility-smoke",
        "fast-portable",
        "full-copas-profile",
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
