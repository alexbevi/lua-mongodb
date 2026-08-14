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
      "deferred_unsupported": 1851,
      "excluded_scope": 2,
      "passed": 3671,
    }, generated["summary"]["statuses"])

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
    self.assertEqual(40, sum(case["status"] == "passed" for case in dns))
    self.assertEqual(4, sum(
      case["activity"] == "ADV-005" and case["status"] == "deferred_unsupported"
      for case in dns
    ))
    self.assertEqual(9, sum(
      case["activity"] == "ADV-006" and case["status"] == "deferred_unsupported"
      for case in dns
    ))

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

  def test_advanced_management_cases_are_post_v1_exclusions(self) -> None:
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
      ["ADV-001"] * len(pre_post_images),
      [cases[identity]["activity"] for identity in pre_post_images],
    )
    self.assertEqual(
      ["ADV-011"] * len(search_indexes),
      [cases[identity]["activity"] for identity in search_indexes],
    )
    self.assertNotIn("REL-017", {case["activity"] for case in cases.values()})


if __name__ == "__main__":
  unittest.main()
