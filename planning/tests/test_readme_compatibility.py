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

  def test_passing_percentage_includes_every_tracked_case(self) -> None:
    self.assertEqual(
      "100.0%",
      readme_compatibility.passing_percentage({"passed": 3}),
    )
    self.assertEqual(
      "66.7%",
      readme_compatibility.passing_percentage({
        "passed": 2,
        "deferred_unsupported": 1,
      }),
    )
    self.assertEqual(
      "0.0%",
      readme_compatibility.passing_percentage({"deferred_unsupported": 3}),
    )

  def test_table_follows_the_onion_and_covers_every_suite(self) -> None:
    suites = {
      suite
      for _, entries in readme_compatibility.DRIVER_LAYERS
      for suite, _ in entries
    }

    self.assertEqual(set(readme_compatibility.suite_counts()), suites)

    table = readme_compatibility.render_table()
    positions = [
      table.index(f"| {layer} |")
      for layer, _ in readme_compatibility.DRIVER_LAYERS
    ]

    self.assertEqual(sorted(positions), positions)
    self.assertIn(
      "| Driver layer | Specification suite | Status | Tests Passing % |",
      table,
    )
    self.assertIn("| Serialization | BSON corpus | 🟢 | 100.0% |", table)
    self.assertIn(
      "| Authentication | Authentication options and additional mechanisms | "
      "🟡 | 30.1% |",
      table,
    )
    self.assertRegex(
      table,
      r"\| Resilience \| Client-side operations timeout \| 🟡 \| \d+\.\d% \|",
    )


if __name__ == "__main__":
  unittest.main()
