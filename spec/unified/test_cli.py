"""Unit tests for unified fixture discovery and capability reporting."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest

from spec.unified import run
from spec.unified import validate_fixtures


class UnifiedCliTests(unittest.TestCase):
  def test_inventory_reports_stable_per_test_identities(self) -> None:
    fixtures = [
      {
        "description": "fixture",
        "path": "crud/tests/unified/find.json",
        "schema_version": "1.0",
        "tests": ["returns one", "returns none"],
      },
    ]

    report = run.build_inventory_report(fixtures)

    self.assertEqual(1, report["summary"]["files"])
    self.assertEqual(2, report["summary"]["tests"])
    self.assertEqual(
      "crud/tests/unified/find.json::test[1]",
      report["tests"][0]["id"],
    )
    self.assertEqual("returns one", report["tests"][0]["description"])

  def test_fixture_validation_rejects_incompatible_schema_versions(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      source = Path(directory)
      relative = "crud/tests/unified/incompatible.json"
      fixture = source / relative
      fixture.parent.mkdir(parents=True)
      fixture.write_text(json.dumps({
        "description": "incompatible",
        "schemaVersion": "2.0",
        "tests": [{"description": "test", "operations": []}],
      }), encoding="utf-8")

      with self.assertRaisesRegex(
        validate_fixtures.ValidationError,
        "incompatible schemaVersion 2.0",
      ):
        validate_fixtures.validate_fixture_documents(
          source,
          [relative],
          os.environ.get("LUA", "lua"),
        )

  def test_discovery_filters_and_rejects_unclassified_fixtures(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      source = Path(directory)
      fixture = source / "crud" / "tests" / "unified" / "find.json"
      fixture.parent.mkdir(parents=True)
      fixture.write_text("{}", encoding="utf-8")

      discovered = run.discover_fixtures(source, ["crud/**"])

      self.assertEqual(["crud/tests/unified/find.json"], discovered)
      with self.assertRaisesRegex(run.CapabilityError, "unclassified fixture"):
        run.classify_fixtures(discovered, {})

  def test_classification_rejects_stale_entries_and_empty_reasons(self) -> None:
    with self.assertRaisesRegex(run.CapabilityError, "undiscovered fixture"):
      run.classify_fixtures([], {
        "old/tests/unified/test.json": {
          "activity": "OLD-001",
          "reason": "old",
          "status": "deferred",
        },
      })

    with self.assertRaisesRegex(run.CapabilityError, "must have a reason"):
      run.classify_fixtures(["a/tests/unified/test.json"], {
        "a/tests/unified/test.json": {
          "activity": "A-001",
          "reason": "",
          "status": "deferred",
        },
      })

  def test_classification_rejects_unknown_activity_owners(self) -> None:
    with self.assertRaisesRegex(run.CapabilityError, "unknown activity owner"):
      run.classify_fixtures(
        ["a/tests/unified/test.json"],
        {
          "a/tests/unified/test.json": {
            "activity": "MISSING-001",
            "reason": "not implemented",
            "status": "deferred",
          },
        },
        {"REAL-001"},
      )

  def test_report_is_machine_readable_and_filters_classifications(self) -> None:
    classified = [
      {
        "activity": "A-001",
        "path": "a/tests/unified/test.json",
        "reason": "not ready",
        "status": "deferred",
      },
      {
        "activity": "B-001",
        "path": "b/tests/unified/test.json",
        "reason": "not ready",
        "status": "deferred",
      },
    ]
    selected = run.select_classifications(classified, ["a/**"])
    report = run.build_report(selected)

    self.assertEqual(1, report["summary"]["selected"])
    self.assertEqual(1, report["summary"]["deferred_unsupported"])
    self.assertEqual(0, report["summary"]["executed"])
    self.assertFalse(report["summary"]["conformant"])
    self.assertEqual("a/tests/unified/test.json", report["fixtures"][0]["path"])
    self.assertEqual("deferred_unsupported", report["fixtures"][0]["status"])


if __name__ == "__main__":
  unittest.main()
