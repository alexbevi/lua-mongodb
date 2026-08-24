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

    requirement_sources = {value["source"] for value in requirements.values()}
    self.assertTrue(prose_sources <= requirement_sources)
    self.assertEqual(
      {"gridfs/gridfs-spec.md"},
      requirement_sources - prose_sources,
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
      source = requirement["source"]
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

  def test_objectid_requirement_records_normative_boundary_execution(self) -> None:
    requirements = catalog.generate()["requirements"]

    for suffix in ("timestamp-boundaries", "counter-rollover"):
      requirement = requirements[f"bson-objectid/objectid.md::{suffix}"]

      self.assertEqual("BSON-009", requirement["activity"])
      self.assertEqual("passed", requirement["status"])
      self.assertEqual("spec/unit/bson_tagged_spec.lua", requirement["runner"])
      self.assertIn("spec/unit/bson_tagged_spec.lua", requirement["last_execution"])

    post_fork = requirements["bson-objectid/objectid.md::post-fork-random"]
    self.assertEqual("BSON-010", post_fork["activity"])
    self.assertEqual("deferred_unsupported", post_fork["status"])
    self.assertIsNone(post_fork["last_execution"])

  def test_enumeration_requirements_record_the_topology_matrix(self) -> None:
    requirements = catalog.generate()["requirements"]

    for source in (
      "enumerate-collections/enumerate-collections.md::document",
      "enumerate-databases/enumerate-databases.md::document",
    ):
      requirement = requirements[source]

      self.assertEqual("ENUM-001", requirement["activity"])
      self.assertEqual("passed", requirement["status"])
      self.assertEqual("deterministic-runtime", requirement["required_environment"])
      self.assertEqual("spec/unit/topology_spec.lua", requirement["runner"])
      self.assertIn("spec/unit/admin_spec.lua", requirement["last_execution"])
      self.assertIn("spec/unit/topology_spec.lua", requirement["last_execution"])

  def test_gridfs_requirements_cover_the_normative_api_surface(self) -> None:
    requirements = catalog.generate()["requirements"]
    gridfs = {
      identity: requirement
      for identity, requirement in requirements.items()
      if requirement["suite"] == "gridfs"
    }

    self.assertEqual(15, len(gridfs))
    self.assertEqual({"passed"}, {value["status"] for value in gridfs.values()})
    self.assertEqual(
      {"spec/unit/gridfs_spec.lua"},
      {value["runner"] for value in gridfs.values()},
    )


if __name__ == "__main__":
  unittest.main()
