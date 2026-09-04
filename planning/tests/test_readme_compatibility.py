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
      readme_compatibility.status_marker({"unsupported": 1}),
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
        "unsupported": 3,
      }),
    )
    self.assertEqual(
      "100.0%",
      readme_compatibility.supported_percentage({
        "passed": 2,
        "unscored_exclusion": 3,
      }),
    )

  def test_unscored_fixtures_are_disclosed(self) -> None:
    counts = readme_compatibility.suite_counts()

    self.assertEqual(74, counts["crud"]["old_server_only"])
    self.assertEqual(19, counts["change-streams"]["old_server_only"])
    self.assertEqual(
      4,
      counts["command-logging-and-monitoring"]["old_server_only"],
    )
    self.assertEqual(3, counts["retryable-writes"]["old_server_only"])
    self.assertEqual(3, counts["sessions"]["old_server_only"])
    self.assertEqual(
      2,
      counts["server-discovery-and-monitoring"]["old_server_only"],
    )
    self.assertEqual(
      1,
      counts["client-side-encryption"]["old_server_only"],
    )
    self.assertEqual(2, counts["auth"]["unscored_exclusion"])
    self.assertEqual(1, counts["load-balancers"]["unscored_exclusion"])

    table = readme_compatibility.render_table()
    self.assertIn(
      "[CRUD](https://alexbevi.com/specifications/crud/crud.html) | "
      "🟢 | 100.0% **†** |",
      table,
    )
    self.assertIn(
      "[Change streams](https://alexbevi.com/specifications/change-streams/"
      "change-streams.html) | 🟢 | 100.0% **†** |",
      table,
    )
    self.assertIn(
      "[Load balancer support](https://alexbevi.com/specifications/"
      "load-balancers/load-balancers.html) | 🟢 | 100.0% **†** |",
      table,
    )
    self.assertIn(
      "[Authentication options and additional mechanisms]"
      "(https://alexbevi.com/specifications/auth/auth.html) | "
      "🟢 | 100.0% **†** |",
      table,
    )
    self.assertIn("|  | **Total** |  | **84.9%** **†** |", table)
    self.assertIn("> [!IMPORTANT]", table)
    self.assertIn("**† Fixtures excluded from scoring.**", table)
    self.assertIn(
      "Percentages marked **†** skip 106 upstream fixtures because their "
      "`runOnRequirements` restrict them to MongoDB versions older than the "
      "supported 7.0 floor",
      table,
    )
    self.assertIn(
      "The ledger also omits 3 explicit superseded or upstream-skipped "
      "fixtures from Authentication options and additional mechanisms (2), "
      "Load balancer support (1).",
      table,
    )
    self.assertIn(
      "The ledger excludes 37 terminal unsupported fixtures from scoring in "
      "URI options (21), Transactions (9), Server discovery and monitoring "
      "(5), Connection monitoring and pooling (2).",
      table,
    )

  def test_terminal_unsupported_rows_are_unscored(self) -> None:
    self.assertEqual(
      "⚪",
      readme_compatibility.status_marker({"unsupported": 1}),
    )
    self.assertEqual(
      "N/A",
      readme_compatibility.supported_percentage({"unsupported": 1}),
    )

    table = readme_compatibility.render_table()
    self.assertIn(
      "| Communication | [OCSP support](https://alexbevi.com/specifications/"
      "ocsp-support/ocsp-support.html) | ⚪ | N/A |",
      table,
    )
    self.assertIn(
      "| Communication | [SOCKS5 proxy support](https://alexbevi.com/"
      "specifications/socks5-support/socks5.html) | "
      "⚪ | N/A |",
      table,
    )
    self.assertIn(
      "| Communication | [URI options](https://alexbevi.com/specifications/"
      "uri-options/uri-options.html) | 🟢 | 100.0% **†** |",
      table,
    )
    self.assertIn("|  | **Total** |  | **84.9%** **†** |", table)

  def test_terminal_unsupported_table_rows_use_badge_only(self) -> None:
    table = readme_compatibility.render_table()

    self.assertIn(
      "| Communication | [OCSP support](https://alexbevi.com/specifications/"
      "ocsp-support/ocsp-support.html) | ⚪ | N/A |",
      table,
    )
    self.assertIn(
      "| Communication | [SOCKS5 proxy support](https://alexbevi.com/"
      "specifications/socks5-support/socks5.html) | ⚪ | N/A |",
      table,
    )

    readme = readme_compatibility.DEFAULT_README.read_text(encoding="utf-8")
    self.assertIn(
      "> 🟢 Complete · 🟡 Partial · 🔴 Not implemented · "
      "⚪ Will not implement",
      readme,
    )

  def test_table_follows_the_onion_and_covers_every_suite(self) -> None:
    suites = {
      suite
      for _, entries in readme_compatibility.DRIVER_LAYERS
      for suite, _ in entries
    }

    self.assertEqual(set(readme_compatibility.suite_counts()), suites)
    self.assertTrue({
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
      "| Driver layer | Specification suite | Status | Pass rate |",
      table,
    )
    self.assertNotIn("Tests Passing", table)
    self.assertIn(
      "| Serialization | [BSON corpus](https://alexbevi.com/specifications/"
      "bson-corpus/bson-corpus.html) | 🟢 | 100.0% |",
      table,
    )
    self.assertIn(
      "| Authentication | [Authentication options and additional mechanisms]"
      "(https://alexbevi.com/specifications/auth/auth.html) | "
      "🟢 | 100.0% **†** |",
      table,
    )
    self.assertRegex(
      table,
      r"\| Resilience \| \[Client-side operations timeout\]"
      r"\(https://alexbevi\.com/specifications/client-side-operations-timeout/"
      r"client-side-operations-timeout\.html\) \| 🟡 \| \d+\.\d% \|",
    )
    self.assertIn("|  | **Total** |  | **84.9%** **†** |", table)
    self.assertIn(
      "| Observability | [Client backpressure](https://alexbevi.com/"
      "specifications/connection-monitoring-and-pooling/"
      "connection-monitoring-and-pooling.html) | ⚪ | N/A |",
      table,
    )
    self.assertNotIn("Atlas SFP testing", table)

  def test_prose_only_rows_use_catalog_requirement_outcomes(self) -> None:
    counts = readme_compatibility.suite_counts()

    self.assertEqual(
      {"passed": 81, "unscored_exclusion": 2},
      dict(counts["auth"]),
    )
    self.assertEqual(
      {"passed": 39, "unscored_exclusion": 1},
      dict(counts["load-balancers"]),
    )
    self.assertEqual({"passed": 11}, dict(counts["compression"]))
    self.assertEqual({"passed": 54}, dict(counts["gridfs"]))

    self.assertEqual({"unsupported": 1}, dict(counts["ocsp-support"]))
    self.assertEqual({"unsupported": 1}, dict(counts["socks5-support"]))

    self.assertEqual(
      {"passed": 4},
      dict(counts["logging"]),
    )

    self.assertEqual(
      {"passed": 1},
      dict(counts["polling-srv-records-for-mongos-discovery"]),
    )

    table = readme_compatibility.render_table()
    self.assertIn(
      "| Communication | [OCSP support](https://alexbevi.com/specifications/"
      "ocsp-support/ocsp-support.html) | ⚪ | N/A |",
      table,
    )
    self.assertIn("[Wire compression]", table)
    self.assertIn(
      "| Communication | [SOCKS5 proxy support](https://alexbevi.com/"
      "specifications/socks5-support/socks5.html) | "
      "⚪ | N/A |",
      table,
    )
    self.assertIn("[Standardized logging]", table)
    self.assertIn("[Periodic SRV polling]", table)
    self.assertNotIn("Atlas SFP testing", table)


if __name__ == "__main__":
  unittest.main()
