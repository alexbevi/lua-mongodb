from __future__ import annotations

import unittest

from planning import update_readme_compatibility as readme_compatibility


class ReadmeCompatibilityTests(unittest.TestCase):
  def test_status_is_derived_from_conformance_results(self) -> None:
    self.assertEqual(
      "🟢",
      readme_compatibility.status_marker({"passed": 3}),
    )
    self.assertEqual(
      "🟡",
      readme_compatibility.status_marker({
        "passed": 2,
        "deferred_unsupported": 1,
      }),
    )
    self.assertEqual(
      "🔴",
      readme_compatibility.status_marker({"deferred_unsupported": 3}),
    )
    self.assertEqual(
      "⚪",
      readme_compatibility.status_marker({
        "no_machine_cases": 1,
        "not_applicable": 2,
      }),
    )

  def test_supported_percentage_counts_only_scored_outcomes(self) -> None:
    self.assertEqual(
      "100.0%",
      readme_compatibility.supported_percentage({"passed": 3}),
    )
    self.assertEqual(
      "66.7%",
      readme_compatibility.supported_percentage({
        "passed": 2,
        "deferred_unsupported": 1,
        "no_machine_cases": 4,
        "not_applicable": 5,
      }),
    )
    self.assertEqual(
      "0.0%",
      readme_compatibility.supported_percentage({"deferred_unsupported": 3}),
    )
    self.assertEqual(
      "N/A",
      readme_compatibility.supported_percentage({
        "no_machine_cases": 1,
        "not_applicable": 2,
      }),
    )

  def test_table_follows_the_onion_and_covers_every_suite(self) -> None:
    suites = {
      suite
      for _, entries in readme_compatibility.DRIVER_LAYERS
      for suite, _ in entries
    }

    self.assertEqual(set(readme_compatibility.suite_counts()), suites)
    self.assertTrue({
      "atlas-sfp-testing",
      "compression",
      "logging",
      "ocsp-support",
      "polling-srv-records-for-mongos-discovery",
      "socks5-support",
    } <= suites)

    table = readme_compatibility.render_table()
    positions = [
      table.index(f"| {layer} |")
      for layer, _ in readme_compatibility.DRIVER_LAYERS
    ]

    self.assertEqual(sorted(positions), positions)
    self.assertIn(
      "| Driver layer | Specification suite | Status | Tracked support % |",
      table,
    )
    self.assertNotIn("Tests Passing", table)
    self.assertIn("| Serialization | BSON corpus | 🟢 | 100.0% |", table)
    self.assertIn(
      "| Authentication | Authentication options and additional mechanisms | "
      "🟡 | 83.6% |",
      table,
    )
    self.assertRegex(
      table,
      r"\| Resilience \| Client-side operations timeout \| 🟡 \| \d+\.\d% \|",
    )

  def test_prose_only_rows_use_catalog_requirement_outcomes(self) -> None:
    counts = readme_compatibility.suite_counts()

    for suite in (
      "atlas-sfp-testing",
      "compression",
      "logging",
      "ocsp-support",
      "socks5-support",
    ):
      self.assertEqual({"deferred_unsupported": 1}, dict(counts[suite]))

    self.assertEqual(
      {"passed": 1},
      dict(counts["polling-srv-records-for-mongos-discovery"]),
    )

    table = readme_compatibility.render_table()
    self.assertIn("| Communication | OCSP support | 🔴 | 0.0% |", table)
    self.assertIn("| Communication | Wire compression | 🔴 | 0.0% |", table)
    self.assertIn("| Communication | SOCKS5 proxy support | 🔴 | 0.0% |", table)
    self.assertIn("| Observability | Standardized logging | 🔴 | 0.0% |", table)
    self.assertIn("| Availability | Periodic SRV polling | 🟢 | 100.0% |", table)
    self.assertIn("| Testability | Atlas SFP testing | 🔴 | 0.0% |", table)


if __name__ == "__main__":
  unittest.main()
