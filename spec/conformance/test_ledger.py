"""Contract tests for the normative specification coverage ledger."""

from __future__ import annotations

import unittest

from spec.conformance import ledger


class ConformanceLedgerTests(unittest.TestCase):
  def test_validation_rejects_added_and_changed_cases(self) -> None:
    discovered = {
      "suite/tests/example.json::test[1]": {
        "fingerprint": "current",
      },
    }
    classified = {
      "suite/tests/example.json::test[1]": {
        "activity": "NEXT-001",
        "fingerprint": "stale",
        "runner": "pending:NEXT-001",
        "scope": "production-core-v1",
        "status": "deferred_unsupported",
      },
    }

    with self.assertRaisesRegex(ledger.LedgerError, "fingerprint"):
      ledger.validate_cases(discovered, classified, {"NEXT-001": "pending"})

    classified["suite/tests/example.json::test[1]"]["fingerprint"] = "current"
    discovered["suite/tests/example.json::test[2]"] = {"fingerprint": "new"}

    with self.assertRaisesRegex(ledger.LedgerError, "unclassified"):
      ledger.validate_cases(discovered, classified, {"NEXT-001": "pending"})

  def test_validation_rejects_added_and_changed_fixture_files(self) -> None:
    discovered = {
      "suite/tests/example.json": {
        "fingerprint": "current",
        "format": "json",
        "suite": "suite",
      },
    }

    with self.assertRaisesRegex(ledger.LedgerError, "untracked"):
      ledger.validate_files(discovered, {})

    classified = {
      "suite/tests/example.json": dict(discovered["suite/tests/example.json"]),
    }
    classified["suite/tests/example.json"]["fingerprint"] = "stale"

    with self.assertRaisesRegex(ledger.LedgerError, "fingerprint"):
      ledger.validate_files(discovered, classified)

  def test_generated_ledger_covers_required_normative_formats(self) -> None:
    generated = ledger.generate()
    required_suites = {
      "bson-corpus",
      "client-side-operations-timeout",
      "connection-monitoring-and-pooling",
      "connection-string",
      "max-staleness",
      "server-discovery-and-monitoring",
      "server-selection",
      "sessions",
      "unified-test-format",
      "uri-options",
    }
    formats = {value["format"] for value in generated["cases"].values()}

    self.assertTrue(required_suites <= set(generated["summary"]["suites"]))
    self.assertEqual({
      "bson-corpus",
      "legacy-list",
      "legacy-phases",
      "legacy-single",
      "unified",
      "unified-meta",
    }, formats)
    self.assertEqual(5524, generated["summary"]["cases"])
    self.assertEqual(2966, generated["summary"]["files"])
    self.assertEqual({
      "deferred_unsupported": 1049,
      "excluded_scope": 98,
      "passed": 4362,
      "unsupported": 15,
    }, generated["summary"]["statuses"])

    compression_options = [
      case for case in generated["cases"].values()
      if case["source"] == "uri-options/tests/compression-options.json"
    ]
    self.assertEqual(5, len(compression_options))
    self.assertTrue(all(
      case["activity"] == "ADV-004"
      and case["status"] == "passed"
      and case["runner"] == "spec/support/config_runner.lua"
      for case in compression_options
    ))

    proxy_options = [
      case for case in generated["cases"].values()
      if case["source"] == "uri-options/tests/proxy-options.json"
    ]
    self.assertEqual(15, len(proxy_options))
    self.assertTrue(all(
      case["activity"] == "ADV-012"
      and case["status"] == "unsupported"
      and case["runner"] == "none:unsupported"
      and case["required_environment"] == "none"
      and case["last_execution"] is None
      for case in proxy_options
    ))

    connection_cases = [
      case for case in generated["cases"].values()
      if case["source"]
        == "load-balancers/tests/non-lb-connection-establishment.json"
    ]
    self.assertEqual(2, len(connection_cases))
    self.assertTrue(all(
      case["activity"] == "LB-003"
      and case["status"] == "passed"
      and case["required_environment"] == "directly-coupled-endpoint"
      for case in connection_cases
    ))

    skipped_connection = generated["cases"][
      "load-balancers/tests/lb-connection-establishment.json::test[1]"
    ]
    self.assertEqual("LB-003", skipped_connection["activity"])
    self.assertEqual("excluded_scope", skipped_connection["status"])
    self.assertIn("skipReason", skipped_connection["reason"])

    sharded_command_cursor = generated["cases"][
      "run-command/tests/unified/runCursorCommand.json::test[1]"
    ]
    self.assertEqual("passed", sharded_command_cursor["status"])
    self.assertEqual("live-sharded", sharded_command_cursor["required_environment"])

    sharded_shutdown = generated["cases"][
      "server-discovery-and-monitoring/tests/unified/"
      "sharded-emit-topology-changed-before-close.json::test[1]"
    ]
    self.assertEqual("passed", sharded_shutdown["status"])
    self.assertEqual("live-sharded", sharded_shutdown["required_environment"])

    monitoring_modes = [
      generated["cases"][
        "server-discovery-and-monitoring/tests/unified/"
        f"serverMonitoringMode.json::test[{index}]"
      ]
      for index in range(1, 7)
    ]
    self.assertEqual(["passed"] * 6, [case["status"] for case in monitoring_modes])
    self.assertEqual(
      ["live-sharded"] * 6,
      [case["required_environment"] for case in monitoring_modes],
    )

    monitor_failures = [
      *[
        generated["cases"][
          "server-discovery-and-monitoring/tests/unified/"
          f"hello-command-error.json::test[{index}]"
        ]
        for index in range(1, 3)
      ],
      *[
        generated["cases"][
          "server-discovery-and-monitoring/tests/unified/"
          f"hello-network-error.json::test[{index}]"
        ]
        for index in range(1, 3)
      ],
      *[
        generated["cases"][
          "server-discovery-and-monitoring/tests/unified/"
          f"hello-timeout.json::test[{index}]"
        ]
        for index in range(1, 3)
      ],
    ]
    self.assertEqual(["passed"] * 6, [case["status"] for case in monitor_failures])
    self.assertEqual(
      ["live-sharded"] * 6,
      [case["required_environment"] for case in monitor_failures],
    )

    streaming_deadline = generated["cases"][
      "server-discovery-and-monitoring/tests/unified/"
      "hello-timeout.json::test[3]"
    ]
    self.assertEqual("passed", streaming_deadline["status"])
    self.assertEqual("live-sharded", streaming_deadline["required_environment"])

    cancelled_check = generated["cases"][
      "server-discovery-and-monitoring/tests/unified/"
      "cancel-server-check.json::test[1]"
    ]
    self.assertEqual("passed", cancelled_check["status"])
    self.assertEqual("live-sharded", cancelled_check["required_environment"])

    unbounded_connect = generated["cases"][
      "server-discovery-and-monitoring/tests/unified/"
      "connectTimeoutMS.json::test[1]"
    ]
    self.assertEqual("passed", unbounded_connect["status"])
    self.assertEqual("live-sharded", unbounded_connect["required_environment"])

    authentication_errors = [
      generated["cases"][
        "server-discovery-and-monitoring/tests/unified/"
        f"{fixture}.json::test[1]"
      ]
      for fixture in (
        "auth-error",
        "auth-misc-command-error",
        "auth-network-error",
        "auth-network-timeout-error",
        "auth-shutdown-error",
      )
    ]
    self.assertEqual(
      ["passed"] * 5,
      [case["status"] for case in authentication_errors],
    )
    self.assertEqual(
      ["live-authenticated-standalone"] * 5,
      [case["required_environment"] for case in authentication_errors],
    )

    application_error_environments = {
      "find-network-error": "live-standalone",
      "find-network-timeout-error": "live-standalone",
      "find-shutdown-error": "live-standalone",
      "insert-network-error": "live-standalone",
      "insert-shutdown-error": "live-standalone",
      "pool-clear-application-error": "live-standalone",
      "pool-clear-checkout-error": "live-authenticated-standalone",
      "pool-cleared-error": "live-replicaset",
    }

    for fixture, environment in application_error_environments.items():
      case = generated["cases"][
        "server-discovery-and-monitoring/tests/unified/"
        f"{fixture}.json::test[1]"
      ]

      self.assertEqual("passed", case["status"])
      self.assertEqual(environment, case["required_environment"])

    interrupted_pool_cases = [
      generated["cases"][
        "server-discovery-and-monitoring/tests/unified/"
        f"interruptInUse-pool-clear.json::test[{index}]"
      ]
      for index in range(1, 4)
    ]
    self.assertEqual(
      ["passed"] * 3,
      [case["status"] for case in interrupted_pool_cases],
    )
    self.assertEqual(
      ["live-replicaset"] * 3,
      [case["required_environment"] for case in interrupted_pool_cases],
    )

    authenticated_min_pool = generated["cases"][
      "server-discovery-and-monitoring/tests/unified/"
      "pool-clear-min-pool-size-error.json::test[1]"
    ]
    self.assertEqual(
      "live-authenticated-standalone",
      authenticated_min_pool["required_environment"],
    )

    authenticated_transaction_controls = [
      generated["cases"][
        "transactions/tests/unified/"
        f"retryable-{operation}-handshake.json::test[1]"
      ]
      for operation in ("abort", "commit")
    ]
    self.assertEqual(
      ["live-authenticated-replicaset"] * 2,
      [case["required_environment"] for case in authenticated_transaction_controls],
    )

    snapshot_transaction = generated["cases"][
      "sessions/tests/snapshot-sessions.json::test[8]"
    ]
    self.assertEqual("passed", snapshot_transaction["status"])
    self.assertEqual("production-core-v1", snapshot_transaction["scope"])
    self.assertEqual("live-replicaset", snapshot_transaction["required_environment"])

    snapshot_server_guards = [
      generated["cases"][
        "sessions/tests/"
        f"snapshot-sessions-not-supported-client-error.json::test[{index}]"
      ]
      for index in range(1, 4)
    ]
    self.assertEqual(
      ["passed"] * 3,
      [case["status"] for case in snapshot_server_guards],
    )
    self.assertEqual(
      ["live-replicaset"] * 3,
      [case["required_environment"] for case in snapshot_server_guards],
    )

    snapshot_server_errors = [
      case
      for identity, case in generated["cases"].items()
      if identity.startswith("sessions/tests/snapshot-sessions-")
        and case["activity"] == "SES-008"
    ]
    self.assertEqual(12, len(snapshot_server_errors))
    self.assertEqual(
      {"passed"},
      {case["status"] for case in snapshot_server_errors},
    )

    snapshot_reads = [
      generated["cases"][f"sessions/tests/snapshot-sessions.json::test[{index}]"]
      for index in range(1, 8)
    ]
    self.assertEqual(
      ["passed"] * 7,
      [case["status"] for case in snapshot_reads],
    )
    self.assertEqual(
      ["SES-006"] * 7,
      [case["activity"] for case in snapshot_reads],
    )

    snapshot_times = [
      generated["cases"][f"sessions/tests/snapshot-sessions.json::test[{index}]"]
      for index in range(9, 14)
    ]
    self.assertEqual(
      ["passed"] * 5,
      [case["status"] for case in snapshot_times],
    )
    self.assertEqual(
      ["SES-007"] * 5,
      [case["activity"] for case in snapshot_times],
    )

    superseded_aws = [
      generated["cases"][
        f"auth/tests/legacy/connection-string.json::test[{index}]"
      ]
      for index in (43, 44)
    ]
    self.assertEqual(
      ["excluded_scope", "excluded_scope"],
      [case["status"] for case in superseded_aws],
    )
    self.assertTrue(all(case["reason"] for case in superseded_aws))
    self.assertTrue(all(case["last_execution"] for case in superseded_aws))

    oidc_credentials = [
      generated["cases"][
        f"auth/tests/legacy/connection-string.json::test[{index}]"
      ]
      for index in range(48, 68)
    ]
    self.assertEqual(
      ["AUTH-010"] * 20,
      [case["activity"] for case in oidc_credentials],
    )
    self.assertEqual(
      ["passed"] * 20,
      [case["status"] for case in oidc_credentials],
    )
    self.assertTrue(all(
      case["runner"] == "spec/support/auth_config_runner.lua"
      for case in oidc_credentials
    ))

    dns = [
      case for case in generated["cases"].values()
      if case["suite"] == "initial-dns-seedlist-discovery"
    ]
    self.assertEqual(53, sum(case["status"] == "passed" for case in dns))
    self.assertEqual(4, sum(
      case["activity"] == "DNS-001" and case["status"] == "passed"
      for case in dns
    ))
    self.assertEqual(9, sum(
      case["activity"] == "ADV-006" and case["status"] == "passed"
      for case in dns
    ))

    load_balanced_selection = [
      case for case in generated["cases"].values()
      if case["activity"] == "LB-001"
    ]
    self.assertEqual(11, len(load_balanced_selection))
    self.assertTrue(all(
      case["status"] == "passed"
      for case in load_balanced_selection
    ))
    self.assertEqual(
      {"spec/unit/selection_spec.lua", "spec/unit/topology_spec.lua"},
      {case["runner"] for case in load_balanced_selection},
    )

    load_balanced_session = generated["cases"][
      "load-balancers/tests/transactions.json::test[1]"
    ]
    self.assertEqual("LB-002", load_balanced_session["activity"])
    self.assertEqual("passed", load_balanced_session["status"])
    self.assertEqual("spec/unit/session_spec.lua", load_balanced_session["runner"])

  def test_unknown_runnable_unified_case_has_no_implicit_executor(self) -> None:
    identity = "crud/tests/unified/insertOne.json::test[2]"
    case = {
      "fingerprint": "current",
      "format": "unified",
      "source": "crud/tests/unified/insertOne.json",
      "suite": "crud",
    }

    with self.assertRaisesRegex(ledger.LedgerError, "no exact executor"):
      ledger.classify_case(
        identity,
        case,
        {"UTF-010": {"milestone": "production-core-v1", "status": "pending"}},
        {identity: {"activity": "UTF-010", "status": "runnable"}},
      )

  def test_advanced_management_cases_keep_vertical_slice_owners(self) -> None:
    cases = ledger.generate()["cases"]
    pre_post_images = [
      "collection-management/tests/"
        "createCollection-pre_and_post_images.json::test[1]",
      "collection-management/tests/"
        "modifyCollection-pre_and_post_images.json::test[1]",
    ]
    search_indexes = [
      *[
        f"index-management/tests/createSearchIndex.json::test[{index}]"
        for index in range(1, 4)
      ],
      *[
        f"index-management/tests/createSearchIndexes.json::test[{index}]"
        for index in range(1, 5)
      ],
      "index-management/tests/dropSearchIndex.json::test[1]",
      *[
        f"index-management/tests/listSearchIndexes.json::test[{index}]"
        for index in range(1, 4)
      ],
      *[
        "index-management/tests/"
          f"searchIndexIgnoresReadWriteConcern.json::test[{index}]"
        for index in range(1, 6)
      ],
      "index-management/tests/updateSearchIndex.json::test[1]",
    ]

    self.assertEqual(
      ["CS-009", "CS-010"],
      [cases[identity]["activity"] for identity in pre_post_images],
    )
    self.assertEqual(
      ["passed", "passed"],
      [cases[identity]["status"] for identity in pre_post_images],
    )
    self.assertEqual(
      [
        *(["IDX-001"] * 3),
        *(["IDX-002"] * 4),
        "IDX-005",
        *(["IDX-003"] * 3),
        *(["IDX-006"] * 5),
        "IDX-004",
      ],
      [cases[identity]["activity"] for identity in search_indexes],
    )
    self.assertEqual(
      ["passed"] * len(search_indexes),
      [cases[identity]["status"] for identity in search_indexes],
    )
    self.assertNotIn("REL-017", {case["activity"] for case in cases.values()})


if __name__ == "__main__":
  unittest.main()
