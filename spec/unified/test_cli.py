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
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_first_standalone_find_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[2]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_first_standalone_insert_many_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertMany.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_first_standalone_command_event_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_first_standalone_failpoint_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertOne-errorResponse.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_mongodb_8_2_raw_data_read_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "crud/tests/unified/aggregate-rawdata.json::test[1]",
      "crud/tests/unified/countDocuments-rawdata.json::test[1]",
      "crud/tests/unified/distinct-rawdata.json::test[1]",
      "crud/tests/unified/estimatedDocumentCount-rawdata.json::test[1]",
      "crud/tests/unified/find-rawdata.json::test[1]",
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )

  def test_drop_index_default_concern_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = (
      "read-write-concern/tests/operation/"
      "default-write-concern-3.4.json::test[3]"
    )

    self.assertEqual("runnable", manifest["tests"][identity]["status"])

  def test_legacy_crud_cases_are_post_v1_exclusions(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "crud/tests/unified/count-collation.json::test[2]",
      "crud/tests/unified/count-empty.json::test[3]",
      "crud/tests/unified/count-rawdata.json::test[1]",
      "crud/tests/unified/count-rawdata.json::test[2]",
      "crud/tests/unified/count.json::test[5]",
      "crud/tests/unified/count.json::test[6]",
      "crud/tests/unified/count.json::test[7]",
    ]
    server_error_fixtures = [
      "bulkWrite-delete-hint-serverError",
      "deleteMany-hint-serverError",
      "deleteOne-hint-serverError",
      "find-allowdiskuse-serverError",
      "findOneAndDelete-hint-serverError",
      "findOneAndReplace-hint-serverError",
      "findOneAndUpdate-hint-serverError",
    ]

    for fixture in server_error_fixtures:
      for index in (1, 2):
        identities.append(f"crud/tests/unified/{fixture}.json::test[{index}]")

    self.assertEqual(
      ["ADV-011"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )

  def test_pre_8_0_write_sort_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "crud/tests/unified/bulkWrite-replaceOne-sort.json::test[2]",
      "crud/tests/unified/bulkWrite-updateOne-sort.json::test[2]",
      "crud/tests/unified/replaceOne-sort.json::test[2]",
      "crud/tests/unified/updateOne-sort.json::test[2]",
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )

  def test_mongodb_8_2_raw_data_write_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    fixtures = [
      "bulkWrite-deleteMany-rawdata",
      "bulkWrite-deleteOne-rawdata",
      "bulkWrite-replaceOne-rawdata",
      "bulkWrite-updateMany-rawdata",
      "bulkWrite-updateOne-rawdata",
      "deleteMany-rawdata",
      "deleteOne-rawdata",
      "findOneAndDelete-rawdata",
      "findOneAndReplace-rawdata",
      "findOneAndUpdate-rawdata",
      "insertMany-rawdata",
      "insertOne-rawdata",
      "replaceOne-rawdata",
      "updateMany-rawdata",
      "updateOne-rawdata",
    ]
    identities = [
      f"crud/tests/unified/{fixture}.json::test[1]" for fixture in fixtures
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )

  def test_pre_5_0_dot_dollar_cases_are_post_v1_exclusions(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "crud/tests/unified/bulkWrite-insertOne-dots_and_dollars.json::test[2]",
      "crud/tests/unified/bulkWrite-replaceOne-dots_and_dollars.json::test[3]",
      "crud/tests/unified/findOneAndReplace-dots_and_dollars.json::test[3]",
      "crud/tests/unified/insertMany-dots_and_dollars.json::test[2]",
      "crud/tests/unified/insertOne-dots_and_dollars.json::test[2]",
      "crud/tests/unified/insertOne-dots_and_dollars.json::test[9]",
      "crud/tests/unified/replaceOne-dots_and_dollars.json::test[3]",
      "crud/tests/unified/replaceOne-dots_and_dollars.json::test[5]",
    ]

    self.assertEqual(
      ["ADV-011"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )

  def test_estimated_count_view_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/estimatedDocumentCount.json::test[6]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])

  def test_aggregate_write_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      *[
        f"crud/tests/unified/aggregate-out-readConcern.json::test[{index}]"
        for index in range(1, 5)
      ],
      *[
        f"crud/tests/unified/aggregate-write-readPreference.json::test[{index}]"
        for index in range(1, 5)
      ],
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["ADV-011", "ADV-011"],
      [
        manifest["tests"][f"crud/tests/unified/aggregate.json::test[{index}]"][
          "activity"
        ]
        for index in (4, 6)
      ],
    )

  def test_management_raw_data_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      *[
        f"collection-management/tests/"
          f"listCollections-rawdata.json::test[{index}]"
        for index in range(1, 3)
      ],
      *[
        f"index-management/tests/index-rawdata.json::test[{index}]"
        for index in range(1, 3)
      ],
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_collection_option_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      *[
        f"collection-management/tests/clustered-indexes.json::test[{index}]"
        for index in range(1, 4)
      ],
      *[
        f"collection-management/tests/timeseries-collection.json::test[{index}]"
        for index in range(1, 4)
      ],
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_index_timeout_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    fixture_indices = {
      "global-timeoutMS.json": range(61, 65),
      "override-collection-timeoutMS.json": range(45, 49),
      "override-database-timeoutMS.json": range(55, 59),
      "override-operation-timeoutMS.json": (33, 34, 61, 62, 63, 64),
    }
    identities = [
      f"client-side-operations-timeout/tests/{fixture}::test[{index}]"
      for fixture, indices in fixture_indices.items()
      for index in indices
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(1263, manifest["ratchets"]["runnable"])
    self.assertEqual(1263, manifest["ratchets"]["passed"])

  def test_modify_collection_error_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "collection-management/tests/modifyCollection-errorResponse.json::test[1]",
      "crud/tests/unified/findOneAndUpdate-errorResponse.json::test[1]",
      "crud/tests/unified/findOneAndUpdate-errorResponse.json::test[2]",
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )

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

  def test_discovery_includes_release_unified_fixture_locations(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      source = Path(directory)
      fixtures = [
        source / "collection-management" / "tests" / "collections.json",
        source / "index-management" / "tests" / "indexes.json",
        source / "versioned-api" / "tests" / "stable.json",
        source / "read-write-concern" / "tests" / "operation" / "concern.json",
      ]

      for fixture in fixtures:
        fixture.parent.mkdir(parents=True, exist_ok=True)
        fixture.write_text("{}", encoding="utf-8")

      self.assertEqual(
        [
          "collection-management/tests/collections.json",
          "index-management/tests/indexes.json",
          "read-write-concern/tests/operation/concern.json",
          "versioned-api/tests/stable.json",
        ],
        run.discover_fixtures(source),
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

  def test_csot_reuses_the_shared_replica_set(self) -> None:
    csot = "client-side-operations-timeout/tests/command-execution.json::test[1]"
    transaction = "transactions/tests/unified/commit.json::test[1]"
    registry = {
      csot: {"environment": "isolated-replicaset", "testCommands": True},
      transaction: {"environment": "isolated-replicaset"},
    }

    effective = run.apply_environment_overrides(registry)

    self.assertEqual("live-replicaset", effective[csot]["environment"])
    self.assertEqual("isolated-replicaset", effective[transaction]["environment"])
    self.assertEqual("isolated-replicaset", registry[csot]["environment"])
    self.assertTrue(effective[csot]["testCommands"])


if __name__ == "__main__":
  unittest.main()
