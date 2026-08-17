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

  def test_prose_only_documents_have_accountable_requirement_records(self) -> None:
    generated = catalog.generate()
    documents = generated["documents"]
    suites = generated["suites"]
    requirements = generated["requirements"]
    prose_sources = {
      identity for identity, document in documents.items()
      if not suites[document["suite"]]["has_machine_fixtures"]
    }

    self.assertEqual(
      {f"{source}::document" for source in prose_sources},
      set(requirements),
    )

    required_fields = {
      "activity",
      "fingerprint",
      "format",
      "last_execution",
      "reason",
      "required_environment",
      "runner",
      "scope",
      "source",
      "specifications_commit",
      "status",
      "suite",
    }

    for identity, requirement in requirements.items():
      source = identity.removesuffix("::document")
      self.assertEqual(required_fields, set(requirement))
      self.assertEqual(documents[source]["fingerprint"], requirement["fingerprint"])
      self.assertEqual("prose", requirement["format"])
      self.assertTrue(requirement["activity"])
      self.assertTrue(requirement["runner"])
      self.assertTrue(requirement["scope"])
      self.assertTrue(requirement["reason"])

      if requirement["status"] == "passed":
        self.assertTrue(requirement["last_execution"])
      else:
        self.assertIsNone(requirement["last_execution"])

  def test_non_execution_outcomes_are_explicit_and_do_not_claim_evidence(self) -> None:
    generated = catalog.generate()
    requirements = generated["requirements"]

    self.assertEqual(
      "no_machine_cases",
      requirements["benchmarking/benchmarking.md::document"]["status"],
    )
    self.assertEqual(
      "not_applicable",
      requirements["bson-binary-uuid/uuid.md::document"]["status"],
    )
    self.assertEqual(
      "not_applicable",
      requirements["dbref/dbref.md::document"]["status"],
    )

    non_execution = {
      identity: requirement
      for identity, requirement in requirements.items()
      if requirement["status"] in {"no_machine_cases", "not_applicable"}
    }
    self.assertEqual(3, len(non_execution))

    for requirement in non_execution.values():
      self.assertIsNone(requirement["last_execution"])
      self.assertEqual("none", requirement["required_environment"])
      self.assertTrue(requirement["runner"].startswith("none:"))
      self.assertTrue(requirement["reason"])

    self.assertEqual(
      {"no_machine_cases": 1, "not_applicable": 2},
      {
        status: count
        for status, count in generated["summary"]["requirement_statuses"].items()
        if status in {"no_machine_cases", "not_applicable"}
      },
    )


if __name__ == "__main__":
  unittest.main()
