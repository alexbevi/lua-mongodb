"""Unit tests for unified fixture discovery and capability reporting."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from spec.unified import run
from spec.unified import update_capabilities
from spec.unified import validate_fixtures


EMPTY_REQUIREMENTS = {
  "arguments": [],
  "entities": [],
  "events": [],
  "has_outcome": False,
  "logs": False,
  "match_operators": [],
  "operations": [],
  "special_operations": [],
  "topologies": [],
}


def discovered_test(identity: str, fingerprint: str = "current") -> dict[str, object]:
  fixture, suffix = identity.split("::test[")
  index = int(suffix[:-1])
  return {
    "description": "test",
    "fingerprint": fingerprint,
    "fixture": fixture,
    "id": identity,
    "index": index,
    "requirements": EMPTY_REQUIREMENTS,
  }


def classification(
  activity: str = "A-001",
  fingerprint: str = "current",
  reason: str = "not ready",
) -> dict[str, object]:
  return {
    "activity": activity,
    "fingerprint": fingerprint,
    "reason": reason,
    "requirements": EMPTY_REQUIREMENTS,
    "status": "deferred_unsupported",
  }


class UnifiedCliTests(unittest.TestCase):
  def test_first_standalone_insert_one_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertOne.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(556, manifest["ratchets"]["runnable"])
    self.assertEqual(556, manifest["ratchets"]["passed"])

  def test_first_standalone_find_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[2]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(556, manifest["ratchets"]["runnable"])
    self.assertEqual(556, manifest["ratchets"]["passed"])

  def test_first_standalone_insert_many_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertMany.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(556, manifest["ratchets"]["runnable"])
    self.assertEqual(556, manifest["ratchets"]["passed"])

  def test_first_standalone_command_event_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(556, manifest["ratchets"]["runnable"])
    self.assertEqual(556, manifest["ratchets"]["passed"])

  def test_first_standalone_failpoint_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertOne-errorResponse.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(556, manifest["ratchets"]["runnable"])
    self.assertEqual(556, manifest["ratchets"]["passed"])

  def test_per_test_classification_rejects_completed_owners_and_stale_content(self) -> None:
    discovered = [discovered_test("crud/tests/unified/find.json::test[1]")]
    classifications = {discovered[0]["id"]: classification("DONE-001", "stale")}

    with self.assertRaisesRegex(run.CapabilityError, "fingerprint"):
      run.classify_tests(
        discovered,
        classifications,
        {"DONE-001": "completed"},
      )

    classifications[discovered[0]["id"]]["fingerprint"] = "current"
    with self.assertRaisesRegex(run.CapabilityError, "completed activity"):
      run.classify_tests(
        discovered,
        classifications,
        {"DONE-001": "completed"},
      )

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
      with self.assertRaisesRegex(run.CapabilityError, "unclassified unified test"):
        run.classify_tests(
          [discovered_test("crud/tests/unified/find.json::test[1]")],
          {},
        )

  def test_classification_rejects_stale_entries_and_empty_reasons(self) -> None:
    with self.assertRaisesRegex(run.CapabilityError, "undiscovered unified test"):
      run.classify_tests([], {
        "old/tests/unified/test.json::test[1]": classification("OLD-001"),
      })

    identity = "a/tests/unified/test.json::test[1]"
    with self.assertRaisesRegex(run.CapabilityError, "must have a reason"):
      run.classify_tests([discovered_test(identity)], {
        identity: classification(reason=""),
      })

  def test_classification_rejects_unknown_activity_owners(self) -> None:
    with self.assertRaisesRegex(run.CapabilityError, "unknown activity owner"):
      identity = "a/tests/unified/test.json::test[1]"
      run.classify_tests(
        [discovered_test(identity)],
        {identity: classification("MISSING-001")},
        {"REAL-001": "pending"},
      )

  def test_classification_rejects_unknown_capabilities(self) -> None:
    identity = "a/tests/unified/test.json::test[1]"
    discovered = discovered_test(identity)
    requirements = dict(EMPTY_REQUIREMENTS)
    requirements["operations"] = ["futureOperation"]
    discovered["requirements"] = requirements
    value = classification()
    value["requirements"] = requirements

    with self.assertRaisesRegex(run.CapabilityError, "unknown operations"):
      run.classify_tests([discovered], {identity: value})

  def test_capability_ratchets_reject_regressions(self) -> None:
    classified = [{"status": "deferred_unsupported"}]

    with self.assertRaisesRegex(run.CapabilityError, "classified regressed"):
      run.validate_ratchets(
        classified,
        {"classified": 2, "passed": 0, "runnable": 0},
      )

  def test_report_is_machine_readable_and_filters_classifications(self) -> None:
    classified = [
      {
        "activity": "A-001",
        "fixture": "a/tests/unified/test.json",
        "id": "a/tests/unified/test.json::test[1]",
        "reason": "not ready",
        "status": "deferred_unsupported",
      },
      {
        "activity": "B-001",
        "fixture": "b/tests/unified/test.json",
        "id": "b/tests/unified/test.json::test[1]",
        "reason": "not ready",
        "status": "deferred_unsupported",
      },
    ]
    selected = run.select_classifications(classified, ["a/**"])
    report = run.build_report(selected)

    self.assertEqual(1, report["summary"]["selected"])
    self.assertEqual(1, report["summary"]["deferred_unsupported"])
    self.assertEqual(0, report["summary"]["executed"])
    self.assertFalse(report["summary"]["conformant"])
    self.assertEqual("a/tests/unified/test.json", report["tests"][0]["fixture"])
    self.assertEqual("deferred_unsupported", report["tests"][0]["status"])

  def test_runnable_executor_failures_are_visible(self) -> None:
    classified = [{
      "activity": "A-001",
      "fixture": "a/tests/unified/test.json",
      "id": "a/tests/unified/test.json::test[1]",
      "status": "runnable",
    }]
    report = run.build_report(
      classified,
      execute=lambda _: ("failed", "adapter rejected operation"),
    )

    self.assertEqual(1, report["summary"]["executed"])
    self.assertEqual(1, report["summary"]["failed"])
    self.assertEqual("failed", report["tests"][0]["status"])
    self.assertEqual("adapter rejected operation", report["tests"][0]["error"])

  def test_unavailable_test_commands_are_environment_skipped(self) -> None:
    classified = [{
      "activity": "UTF-014",
      "fixture": "crud/tests/unified/failpoint.json",
      "id": "crud/tests/unified/failpoint.json::test[1]",
      "status": "runnable",
    }]
    completed = subprocess.CompletedProcess(
      args=[],
      returncode=75,
      stdout="",
      stderr="unified executor: test commands are unavailable",
    )

    with mock.patch("spec.unified.run.subprocess.run", return_value=completed):
      executor = run.lua_executor("lua", Path("execute.lua"), {})
      report = run.build_report(
        classified,
        {"classified": 1, "passed": 1, "runnable": 1},
        executor,
      )

    self.assertEqual(0, report["summary"]["executed"])
    self.assertEqual(0, report["summary"]["failed"])
    self.assertEqual(1, report["summary"]["environment_skipped"])
    self.assertEqual("environment_skipped", report["tests"][0]["status"])


if __name__ == "__main__":
  unittest.main()
