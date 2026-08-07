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
      "deferred_unsupported": 2127,
      "passed": 3397,
    }, generated["summary"]["statuses"])

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


if __name__ == "__main__":
  unittest.main()
