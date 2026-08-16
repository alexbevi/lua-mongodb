"""Unit tests for unified fixture discovery and capability reporting."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
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
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_first_standalone_find_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[2]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_all_oidc_no_retry_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"auth/tests/unified/mongodb-oidc-no-retry.json::test[{index}]"
      for index in range(1, 7)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["AUTH-011", "AUTH-011", "AUTH-018", "AUTH-018", "AUTH-017", "AUTH-017"],
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

    registry = run.load_executor_registry()

    for identity in identities:
      self.assertEqual("deterministic-loopback", registry[identity]["environment"])

  def test_first_standalone_insert_many_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertMany.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_first_standalone_command_event_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/find.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_sensitive_command_redaction_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    prefix = (
      "command-logging-and-monitoring/tests/monitoring/"
      "redacted-commands.json::test"
    )
    runnable = [f"{prefix}[{index}]" for index in (1, 2, 3, 5, 6, 7, 8, 9, 10)]
    pre_v1 = f"{prefix}[4]"

    self.assertEqual(
      ["runnable"] * len(runnable),
      [manifest["tests"][identity]["status"] for identity in runnable],
    )
    self.assertEqual(
      ["REL-008"] * len(runnable),
      [manifest["tests"][identity]["activity"] for identity in runnable],
    )
    self.assertEqual("deferred_unsupported", manifest["tests"][pre_v1]["status"])
    self.assertEqual("ADV-011", manifest["tests"][pre_v1]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

    registry = run.load_executor_registry()

    for identity in runnable:
      self.assertEqual(
        {"activity": "REL-008", "environment": "live-standalone"},
        registry[identity],
      )

  def test_first_standalone_failpoint_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "crud/tests/unified/insertOne-errorResponse.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_handshake_metadata_lifecycle_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "mongodb-handshake/tests/unified/metadata-not-propagated.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_generic_command_cursor_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"run-command/tests/unified/runCursorCommand.json::test[{index}]"
      for index in (2, 3, 4, 7, 8, 9)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_command_cursor_timeout_validation_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"client-side-operations-timeout/tests/runCursorCommand.json::test[{index}]"
      for index in (1, 2)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_command_cursor_pool_event_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "client-side-operations-timeout/tests/runCursorCommand.json::test[3]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-024", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_cursor_timeout_cleanup_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"client-side-operations-timeout/tests/close-cursors.json::test[{index}]"
      for index in (1, 2)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["REL-025"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_legacy_write_timeout_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "client-side-operations-timeout/tests/legacy-timeouts.json::test[3]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-026", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_legacy_retry_timeout_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    indices = (
      *range(1, 23),
      *range(27, 31),
      *range(33, 35),
      *range(37, 49),
    )
    identities = [
      "client-side-operations-timeout/tests/"
      f"retryability-legacy-timeouts.json::test[{index}]"
      for index in indices
    ]

    self.assertEqual(
      {"runnable"},
      {manifest["tests"][identity]["status"] for identity in identities},
    )
    self.assertEqual(
      {"REL-006"},
      {manifest["tests"][identity]["activity"] for identity in identities},
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_retryable_read_handshake_error_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    applicable = (
      *range(1, 5),
      *range(9, 13),
      *range(15, 31),
    )
    post_v1 = {
      **{index: "ADV-001" for index in (5, 6, 13, 14, 31, 32)},
      **{index: "ADV-011" for index in (7, 8)},
    }
    identities = {
      index: (
        "retryable-reads/tests/unified/handshakeError.json"
        f"::test[{index}]"
      )
      for index in (*applicable, *post_v1)
    }

    self.assertEqual(
      {"runnable"},
      {manifest["tests"][identities[index]]["status"] for index in applicable},
    )
    self.assertEqual(
      {"REL-034"},
      {manifest["tests"][identities[index]]["activity"] for index in applicable},
    )
    self.assertEqual(
      post_v1,
      {
        index: manifest["tests"][identities[index]]["activity"]
        for index in post_v1
      },
    )
    self.assertEqual(
      {"deferred_unsupported"},
      {manifest["tests"][identities[index]]["status"] for index in post_v1},
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_retryable_write_handshake_error_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    applicable = range(3, 21)
    post_v1 = {index: "ADV-007" for index in (1, 2)}
    identities = {
      index: (
        "retryable-writes/tests/unified/handshakeError.json"
        f"::test[{index}]"
      )
      for index in (*applicable, *post_v1)
    }

    self.assertEqual(
      {"runnable"},
      {manifest["tests"][identities[index]]["status"] for index in applicable},
    )
    self.assertEqual(
      {"REL-035"},
      {manifest["tests"][identities[index]]["activity"] for index in applicable},
    )
    self.assertEqual(
      post_v1,
      {
        index: manifest["tests"][identities[index]]["activity"]
        for index in post_v1
      },
    )
    self.assertEqual(
      {"deferred_unsupported"},
      {manifest["tests"][identities[index]]["status"] for index in post_v1},
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_transaction_abort_handshake_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = (
      "transactions/tests/unified/retryable-abort-handshake.json::test[1]"
    )

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-036", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])
    self.assertEqual(
      {
        "activity": "REL-036",
        "environment": "live-replicaset",
        "runSkipped": True,
        "testCommands": True,
      },
      run.load_executor_registry()[identity],
    )

  def test_transaction_commit_handshake_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = (
      "transactions/tests/unified/retryable-commit-handshake.json::test[1]"
    )

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-037", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])
    self.assertEqual(
      {
        "activity": "REL-037",
        "environment": "live-replicaset",
        "runSkipped": True,
        "testCommands": True,
      },
      run.load_executor_registry()[identity],
    )

  def test_min_pool_connection_error_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = (
      "server-discovery-and-monitoring/tests/unified/"
      "minPoolSize-error.json::test[1]"
    )

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-038", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])
    self.assertEqual(
      {
        "activity": "REL-038",
        "environment": "live-standalone",
        "testCommands": True,
      },
      run.load_executor_registry()[identity],
    )

  def test_min_pool_clear_error_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      "server-discovery-and-monitoring/tests/unified/"
        f"pool-clear-min-pool-size-error.json::test[{index}]"
      for index in range(1, 3)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["REL-039"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

    for identity in identities:
      self.assertEqual(
        {
          "activity": "REL-039",
          "environment": "live-standalone",
          "testCommands": True,
        },
        run.load_executor_registry()[identity],
      )

  def test_step_down_rediscovery_case_uses_three_members(self) -> None:
    manifest = update_capabilities.generate()
    identity = (
      "server-discovery-and-monitoring/tests/unified/"
      "rediscover-quickly-after-step-down.json::test[1]"
    )

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("REL-040", manifest["tests"][identity]["activity"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])
    self.assertEqual(
      {
        "activity": "REL-040",
        "environment": "isolated-replicaset",
        "replicaSetMembers": 3,
      },
      run.load_executor_registry()[identity],
    )

  def test_topology_close_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = {
      "server-discovery-and-monitoring/tests/unified/"
        "replicaset-emit-topology-changed-before-close.json::test[1]": (
          "live-replicaset"
        ),
      "server-discovery-and-monitoring/tests/unified/"
        "standalone-emit-topology-changed-before-close.json::test[1]": (
          "live-standalone"
        ),
    }
    registry = run.load_executor_registry()

    for identity, environment in identities.items():
      self.assertEqual("runnable", manifest["tests"][identity]["status"])
      self.assertEqual("REL-041", manifest["tests"][identity]["activity"])
      self.assertEqual(
        {"activity": "REL-041", "environment": environment},
        registry[identity],
      )

    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

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
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

  def test_single_search_index_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"index-management/tests/createSearchIndex.json::test[{index}]"
      for index in range(1, 4)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["IDX-001"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    registry = run.load_executor_registry()

    self.assertEqual(
      ["live-replicaset"] * len(identities),
      [registry[identity]["environment"] for identity in identities],
    )

  def test_multiple_search_index_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"index-management/tests/createSearchIndexes.json::test[{index}]"
      for index in range(1, 5)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["IDX-002"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    registry = run.load_executor_registry()

    self.assertEqual(
      ["live-replicaset"] * len(identities),
      [registry[identity]["environment"] for identity in identities],
    )

  def test_list_search_index_cases_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identities = [
      f"index-management/tests/listSearchIndexes.json::test[{index}]"
      for index in range(1, 4)
    ]

    self.assertEqual(
      ["runnable"] * len(identities),
      [manifest["tests"][identity]["status"] for identity in identities],
    )
    self.assertEqual(
      ["IDX-003"] * len(identities),
      [manifest["tests"][identity]["activity"] for identity in identities],
    )
    registry = run.load_executor_registry()

    self.assertEqual(
      ["live-replicaset"] * len(identities),
      [registry[identity]["environment"] for identity in identities],
    )

  def test_update_search_index_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "index-management/tests/updateSearchIndex.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("IDX-004", manifest["tests"][identity]["activity"])
    registry = run.load_executor_registry()

    self.assertEqual("live-replicaset", registry[identity]["environment"])

  def test_drop_search_index_case_is_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "index-management/tests/dropSearchIndex.json::test[1]"

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("IDX-005", manifest["tests"][identity]["activity"])
    registry = run.load_executor_registry()

    self.assertEqual("live-replicaset", registry[identity]["environment"])

  def test_snapshot_local_rejections_are_runnable(self) -> None:
    manifest = update_capabilities.generate()
    identity = "sessions/tests/snapshot-sessions.json::test[8]"
    snapshot_reads = [
      f"sessions/tests/snapshot-sessions.json::test[{index}]"
      for index in range(1, 8)
    ]
    snapshot_times = [
      f"sessions/tests/snapshot-sessions.json::test[{index}]"
      for index in range(9, 14)
    ]
    guarded = [
      f"sessions/tests/snapshot-sessions-not-supported-client-error.json::test[{index}]"
      for index in range(1, 4)
    ]
    server_errors = [
      *[
        f"sessions/tests/snapshot-sessions-not-supported-server-error.json::test[{index}]"
        for index in range(1, 4)
      ],
      *[
        f"sessions/tests/snapshot-sessions-unsupported-ops.json::test[{index}]"
        for index in range(1, 10)
      ],
    ]

    self.assertEqual("runnable", manifest["tests"][identity]["status"])
    self.assertEqual("SES-004", manifest["tests"][identity]["activity"])
    self.assertEqual(
      ["runnable"] * len(snapshot_reads),
      [manifest["tests"][case]["status"] for case in snapshot_reads],
    )
    self.assertEqual(
      ["SES-006"] * len(snapshot_reads),
      [manifest["tests"][case]["activity"] for case in snapshot_reads],
    )
    self.assertEqual(
      ["runnable"] * len(snapshot_times),
      [manifest["tests"][case]["status"] for case in snapshot_times],
    )
    self.assertEqual(
      ["SES-007"] * len(snapshot_times),
      [manifest["tests"][case]["activity"] for case in snapshot_times],
    )
    self.assertEqual(
      ["SES-005"] * len(guarded),
      [manifest["tests"][case]["activity"] for case in guarded],
    )
    self.assertEqual(
      ["runnable"] * len(guarded),
      [manifest["tests"][case]["status"] for case in guarded],
    )
    self.assertEqual(
      ["SES-008"] * len(server_errors),
      [manifest["tests"][case]["activity"] for case in server_errors],
    )
    self.assertEqual(
      ["runnable"] * len(server_errors),
      [manifest["tests"][case]["status"] for case in server_errors],
    )
    registry = run.load_executor_registry()

    for case in [identity, *snapshot_reads, *snapshot_times, *guarded]:
      self.assertEqual("live-replicaset", registry[case]["environment"])
    for case in server_errors[:3]:
      self.assertEqual("live-standalone", registry[case]["environment"])
    for case in server_errors[3:]:
      self.assertEqual("live-replicaset", registry[case]["environment"])
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

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
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

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
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

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

  def test_command_cursor_release_cases_keep_vertical_slice_owners(self) -> None:
    manifest = update_capabilities.generate()
    expected = {
      **{
        f"run-command/tests/unified/runCommand.json::test[{index}]": "REL-005"
        for index in (*range(1, 10), 11)
      },
      **{
        f"run-command/tests/unified/runCursorCommand.json::test[{index}]": "REL-022"
        for index in (2, 3, 4, 7, 8, 9)
      },
      "client-side-operations-timeout/tests/runCursorCommand.json::test[1]": "REL-023",
      "client-side-operations-timeout/tests/runCursorCommand.json::test[2]": "REL-023",
      "client-side-operations-timeout/tests/runCursorCommand.json::test[3]": "REL-024",
      "client-side-operations-timeout/tests/close-cursors.json::test[1]": "REL-025",
      "client-side-operations-timeout/tests/close-cursors.json::test[2]": "REL-025",
      "client-side-operations-timeout/tests/legacy-timeouts.json::test[3]": "REL-026",
    }
    post_v1 = {
      "run-command/tests/unified/runCursorCommand.json::test[1]": "ADV-005",
      "run-command/tests/unified/runCursorCommand.json::test[5]": "ADV-006",
      "run-command/tests/unified/runCursorCommand.json::test[6]": "ADV-006",
      "run-command/tests/unified/runCursorCommand.json::test[10]": "ADV-011",
      **{
        f"client-side-operations-timeout/tests/runCursorCommand.json::test[{index}]": "ADV-011"
        for index in (4, 5, 6)
      },
      **{
        f"client-side-operations-timeout/tests/tailable-awaitData.json::test[{index}]": "ADV-011"
        for index in range(9, 14)
      },
      **{
        f"client-side-operations-timeout/tests/tailable-non-awaitData.json::test[{index}]": "ADV-011"
        for index in range(3, 5)
      },
    }

    self.assertEqual(
      {**expected, **post_v1},
      {
        identity: manifest["tests"][identity]["activity"]
        for identity in {**expected, **post_v1}
      },
    )
    generic_commands = [
      identity for identity, activity in expected.items()
      if activity == "REL-005"
    ]
    self.assertEqual(
      ["runnable"] * len(generic_commands),
      [manifest["tests"][identity]["status"] for identity in generic_commands],
    )
    self.assertEqual(1431, manifest["ratchets"]["runnable"])
    self.assertEqual(1431, manifest["ratchets"]["passed"])

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
        source / "sessions" / "tests" / "snapshot-sessions.json",
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
          "sessions/tests/snapshot-sessions.json",
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

  def test_ratchet_failures_identify_the_failed_cases(self) -> None:
    identity = "a/tests/unified/test.json::test[1]"
    classified = [{
      "activity": "A-001",
      "fixture": "a/tests/unified/test.json",
      "id": identity,
      "status": "runnable",
    }]

    with self.assertRaisesRegex(
      run.CapabilityError,
      rf"capability passed regressed from 1 to 0; {re.escape(identity)}: timed out",
    ):
      run.build_report(
        classified,
        {"classified": 1, "passed": 1, "runnable": 1},
        execute=lambda _: ("failed", "timed out"),
      )

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

  def test_fixture_batch_launches_one_lua_executor_for_multiple_tests(self) -> None:
    first = {
      "fixture": "crud/tests/unified/insertOne.json",
      "id": "crud/tests/unified/insertOne.json::test[1]",
      "status": "runnable",
    }
    second = {
      "fixture": "crud/tests/unified/insertOne.json",
      "id": "crud/tests/unified/insertOne.json::test[2]",
      "status": "runnable",
    }
    completed = subprocess.CompletedProcess(
      args=[],
      returncode=0,
      stdout=json.dumps({
        "results": [
          {"id": first["id"], "status": "passed"},
          {
            "error": "runOnRequirements not satisfied",
            "id": second["id"],
            "status": "environment_skipped",
          },
        ],
      }),
      stderr="",
    )

    with mock.patch(
      "spec.unified.run.subprocess.run", return_value=completed,
    ) as execute:
      results = run.lua_batch_executor(
        "lua", Path("execute.lua"), {},
      )([first, second])

    execute.assert_called_once()
    self.assertEqual(
      ["lua", "execute.lua", first["id"], second["id"]],
      execute.call_args.args[0],
    )
    self.assertEqual(("passed", None), results[first["id"]])
    self.assertEqual(
      ("environment_skipped", "runOnRequirements not satisfied"),
      results[second["id"]],
    )

  def test_execution_batches_are_stable_per_fixture_and_environment(self) -> None:
    classifications = [
      {
        "fixture": "crud/tests/unified/insertOne.json",
        "id": "crud/tests/unified/insertOne.json::test[1]",
        "status": "runnable",
      },
      {
        "fixture": "crud/tests/unified/insertOne.json",
        "id": "crud/tests/unified/insertOne.json::test[2]",
        "status": "runnable",
      },
      {
        "fixture": "crud/tests/unified/insertOne.json",
        "id": "crud/tests/unified/insertOne.json::test[3]",
        "status": "deferred_unsupported",
      },
      {
        "fixture": "crud/tests/unified/find.json",
        "id": "crud/tests/unified/find.json::test[1]",
        "status": "runnable",
      },
    ]
    registry = {
      classifications[0]["id"]: {"environment": "live-standalone"},
      classifications[1]["id"]: {"environment": "live-standalone"},
      classifications[3]["id"]: {"environment": "live-replicaset"},
    }

    batches = run.execution_batches(classifications, registry)

    self.assertEqual(
      [[classifications[0], classifications[1]], [classifications[3]]],
      batches,
    )

  def test_execution_timings_are_observational_and_report_slowest_groups(
    self,
  ) -> None:
    classifications = [
      {
        "activity": "A-001",
        "fixture": "crud/tests/unified/insertOne.json",
        "id": "crud/tests/unified/insertOne.json::test[1]",
        "status": "runnable",
      },
      {
        "activity": "A-001",
        "fixture": "crud/tests/unified/find.json",
        "id": "crud/tests/unified/find.json::test[1]",
        "status": "runnable",
      },
    ]
    report = run.build_report(
      classifications,
      {"classified": 2, "passed": 2, "runnable": 2},
      execute=lambda _: ("passed", None),
    )
    conformance = json.loads(json.dumps(report))
    clock = mock.Mock(side_effect=[0, 1, 2, 7, 8, 11, 12, 18, 20])
    timings = run.ExecutionTimings(clock=clock)

    timings.finish_setup()

    with timings.observe_environment("live-standalone"):
      pass

    with timings.observe_fixture_group([classifications[0]], "live-standalone"):
      pass

    with timings.observe_fixture_group([classifications[1]], "live-replicaset"):
      pass

    timings.attach(report)

    self.assertEqual(
      conformance,
      {key: value for key, value in report.items() if key != "timings"},
    )
    self.assertEqual(1000.0, report["timings"]["setup_ms"])
    self.assertEqual(20000.0, report["timings"]["total_ms"])
    self.assertEqual(
      [{
        "duration_ms": 5000.0,
        "environment": "live-standalone",
      }],
      report["timings"]["environments"],
    )
    self.assertEqual(
      [
        {
          "duration_ms": 6000.0,
          "environment": "live-replicaset",
          "fixture": "crud/tests/unified/find.json",
          "tests": 1,
        },
        {
          "duration_ms": 3000.0,
          "environment": "live-standalone",
          "fixture": "crud/tests/unified/insertOne.json",
          "tests": 1,
        },
      ],
      report["timings"]["slowest_fixture_groups"],
    )

  def test_batch_report_omission_fails_every_selected_identity(self) -> None:
    classifications = [
      {
        "id": "crud/tests/unified/insertMany.json::test[1]",
        "status": "runnable",
      },
      {
        "id": "crud/tests/unified/insertMany.json::test[2]",
        "status": "runnable",
      },
    ]
    completed = subprocess.CompletedProcess(
      args=[],
      returncode=0,
      stdout=json.dumps({
        "results": [{"id": classifications[0]["id"], "status": "passed"}],
      }),
      stderr="",
    )

    with mock.patch("spec.unified.run.subprocess.run", return_value=completed):
      results = run.lua_batch_executor(
        "lua", Path("execute.lua"), {},
      )(classifications)

    self.assertEqual(
      {"failed"},
      {status for status, _ in results.values()},
    )
    self.assertTrue(all(
      detail == "unified executor omitted a selected test identity"
      for _, detail in results.values()
    ))

  def test_fixture_shards_are_stable_disjoint_and_complete(self) -> None:
    classifications = [
      {
        "fixture": f"suite/tests/unified/fixture-{fixture}.json",
        "id": f"suite/tests/unified/fixture-{fixture}.json::test[{index}]",
        "status": "runnable",
      }
      for fixture in range(20)
      for index in range(1, 3)
    ]
    shards = [
      run.select_shard(classifications, 4, index)
      for index in range(4)
    ]
    selected_ids = [
      classification["id"]
      for shard in shards
      for classification in shard
    ]

    self.assertEqual(
      {classification["id"] for classification in classifications},
      set(selected_ids),
    )
    self.assertEqual(len(selected_ids), len(set(selected_ids)))

    for fixture in {value["fixture"] for value in classifications}:
      containing = [
        index for index, shard in enumerate(shards)
        if any(value["fixture"] == fixture for value in shard)
      ]
      self.assertEqual([run.fixture_shard(fixture, 4)], containing)

    self.assertEqual(
      [1, 2, 1, 1, 3],
      [
        run.fixture_shard(
          f"suite/tests/unified/fixture-{index}.json",
          4,
        )
        for index in range(5)
      ],
    )

  def test_shard_aggregation_enforces_exact_global_ratchets(self) -> None:
    classifications = [
      {
        "activity": "A-001",
        "fixture": f"suite/tests/unified/fixture-{index}.json",
        "id": f"suite/tests/unified/fixture-{index}.json::test[1]",
        "status": "runnable",
      }
      for index in range(8)
    ]
    ratchets = {"classified": 8, "passed": 8, "runnable": 8}
    reports = []

    for index in range(4):
      selected = run.select_shard(classifications, 4, index)
      report = run.build_report(
        selected,
        execute=lambda _: ("passed", None),
      )
      report["shard"] = {"count": 4, "index": index}
      report["timings"] = {
        "environments": [{
          "duration_ms": 2.0,
          "environment": "live-standalone",
        }],
        "fixture_groups": [
          {
            "duration_ms": float(index + position + 1),
            "environment": "live-standalone",
            "fixture": classification["fixture"],
            "tests": 1,
          }
          for position, classification in enumerate(selected)
        ],
        "setup_ms": 1.0,
        "slowest_fixture_groups": [],
        "total_ms": 10.0,
      }
      reports.append(report)

    aggregate = run.aggregate_shard_reports(classifications, ratchets, reports)

    self.assertEqual(8, aggregate["summary"]["executed"])
    self.assertEqual(8, aggregate["summary"]["passed"])
    self.assertEqual(0, aggregate["summary"]["failed"])
    self.assertEqual(4.0, aggregate["timings"]["setup_ms"])
    self.assertEqual(40.0, aggregate["timings"]["total_ms"])
    self.assertEqual(8.0, aggregate["timings"]["environments"][0]["duration_ms"])
    self.assertEqual(8, len(aggregate["timings"]["fixture_groups"]))
    self.assertEqual(
      max(
        group["duration_ms"]
        for report in reports
        for group in report["timings"]["fixture_groups"]
      ),
      aggregate["timings"]["slowest_fixture_groups"][0]["duration_ms"],
    )

    reports[0]["tests"].pop()

    with self.assertRaisesRegex(run.CapabilityError, "missing test identity"):
      run.aggregate_shard_reports(classifications, ratchets, reports)

    reports = []

    for index in range(4):
      selected = run.select_shard(classifications, 4, index)
      report = run.build_report(
        selected,
        execute=lambda _: ("passed", None),
      )
      report["shard"] = {"count": 4, "index": index}
      reports.append(report)

    reports[1]["tests"].append(reports[0]["tests"][0])

    with self.assertRaisesRegex(run.CapabilityError, "duplicate shard test identity"):
      run.aggregate_shard_reports(classifications, ratchets, reports)

    reports[1]["tests"].pop()
    reports[0]["tests"][0]["status"] = "failed"
    reports[0]["tests"][0]["error"] = "shard execution failed"

    with self.assertRaisesRegex(run.CapabilityError, "capability passed regressed"):
      run.aggregate_shard_reports(classifications, ratchets, reports)

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

  def test_macos_ci_skips_only_timing_sensitive_csot_cases(self) -> None:
    sensitive = [
      "client-side-operations-timeout/tests/close-cursors.json::test[1]",
      "client-side-operations-timeout/tests/close-cursors.json::test[2]",
      "client-side-operations-timeout/tests/command-execution.json::test[1]",
      "client-side-operations-timeout/tests/command-execution.json::test[2]",
      "client-side-operations-timeout/tests/command-execution.json::test[3]",
      "client-side-operations-timeout/tests/non-tailable-cursors.json::test[2]",
      "client-side-operations-timeout/tests/non-tailable-cursors.json::test[3]",
      "client-side-operations-timeout/tests/non-tailable-cursors.json::test[5]",
      "client-side-operations-timeout/tests/runCursorCommand.json::test[3]",
    ]

    for identity in sensitive:
      self.assertIsNotNone(
        run.platform_environment_skip(identity, {"CI": "true"}, "darwin")
      )

    stable = "client-side-operations-timeout/tests/non-tailable-cursors.json::test[1]"
    self.assertIsNone(run.platform_environment_skip(stable, {"CI": "true"}, "darwin"))
    self.assertIsNone(run.platform_environment_skip(sensitive[0], {}, "darwin"))
    self.assertIsNone(
      run.platform_environment_skip(sensitive[0], {"CI": "true"}, "linux")
    )


if __name__ == "__main__":
  unittest.main()
