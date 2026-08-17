"""Contract tests for the accepted specification document catalog."""

from __future__ import annotations

import re
import unittest

from spec.conformance import catalog


class ConformanceCatalogTests(unittest.TestCase):
  def test_catalog_covers_every_accepted_document_and_onion_suite(self) -> None:
    generated = catalog.generate()
    documents = generated["documents"]
    suites = generated["suites"]

    self.assertEqual(57, len(documents))
    self.assertEqual(50, len(suites))
    self.assertEqual(
      {
        "Authentication",
        "Availability",
        "Communication",
        "Connectivity",
        "Observability",
        "Programmability",
        "Resilience",
        "Serialization",
        "Testability",
      },
      {suite["layer"] for suite in suites.values()},
    )

    for identity, document in documents.items():
      self.assertEqual(document["source"], identity)
      self.assertIn(document["suite"], suites)
      self.assertRegex(document["fingerprint"], re.compile(r"^[0-9a-f]{64}$"))

    fixtureless = {
      "atlas-sfp-testing",
      "benchmarking",
      "bson-objectid",
      "compression",
      "enumerate-collections",
      "enumerate-databases",
      "logging",
      "message",
      "ocsp-support",
      "polling-srv-records-for-mongos-discovery",
      "socks5-support",
    }
    self.assertTrue(fixtureless <= set(suites))
    self.assertTrue(all(not suites[name]["has_machine_fixtures"] for name in fixtureless))


if __name__ == "__main__":
  unittest.main()
