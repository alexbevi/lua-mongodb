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
    self.assertIn("| Serialization | BSON corpus | 🟢 |", table)
    self.assertIn(
      "| Authentication | Authentication options and additional mechanisms | 🔴 |",
      table,
    )
    self.assertIn("| Resilience | Client-side operations timeout | 🟡 |", table)


if __name__ == "__main__":
  unittest.main()
