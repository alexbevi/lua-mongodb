from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v10 import scope


class V10ScopeTests(unittest.TestCase):
  def exact_report(
    self,
    identity: str | None = None,
    status: str = "passed",
    error: str | None = None,
  ) -> dict[str, object]:
    rows = [
      {"id": case_identity, "status": "passed"}
      for case_identity in scope.generate()["exact_unified_cases"]
    ]

    if identity is not None:
      row = next(value for value in rows if value["id"] == identity)
      row["status"] = status

      if error is not None:
        row["error"] = error

    return {
      "ratchets": scope.load_capability_ratchets(),
      "tests": rows,
      "type": "execution",
    }

  def test_generated_scope_closes_load_balancing(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 1044,
        "excluded": 18,
        "passed": 780,
        "planned": 0,
        "supported": 780,
        "unsupported": 246,
      },
      generated["summary"],
    )
    self.assertEqual(
      {
        "dedicated_cases": 40,
        "exact_unified_cases": 741,
        "run_on_branches": 1002,
        "terminal_unsupported": 246,
      },
      generated["evidence"],
    )

  def test_every_load_balanced_identity_is_classified(self) -> None:
    generated = scope.generate()

    self.assertEqual(
      {
        identity
        for identity, case in scope.load_cases().items()
        if case["suite"] == "load-balancers"
      },
      set(generated["dedicated_cases"]),
    )
    self.assertEqual(
      {
        identity
        for identity, capability in scope.load_capabilities().items()
        if scope._is_load_balanced_branch(capability)
      },
      set(generated["run_on_branches"]),
    )

  def test_exact_execution_rejects_missing_failed_and_skipped_targets(self) -> None:
    identity = sorted(scope.CLOSURE_EXECUTORS)[0]
    missing = self.exact_report()
    missing["tests"] = [
      row for row in missing["tests"] if row["id"] != identity
    ]

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(missing, scope.load_capability_ratchets())

    with self.assertRaisesRegex(scope.ScopeError, "unknown unified operation"):
      scope.validate_execution(
        self.exact_report(
          identity,
          "failed",
          "unknown unified operation: futureOperation",
        ),
        scope.load_capability_ratchets(),
      )

    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.validate_execution(
        self.exact_report(identity, "environment_skipped"),
        scope.load_capability_ratchets(),
      )

  def test_exact_execution_allows_only_pre_floor_target_skips(self) -> None:
    report = self.exact_report()

    for row in report["tests"]:
      if row["id"] in scope.TARGET_VERSION_EXECUTION_EXCLUSIONS:
        row["status"] = "environment_skipped"

    expected = len(scope.generate()["exact_unified_cases"]) - len(
      scope.TARGET_VERSION_EXECUTION_EXCLUSIONS
    )
    self.assertEqual(
      {"passed": expected, "required": expected},
      scope.validate_execution(report, scope.load_capability_ratchets()),
    )

  def test_authenticated_handshake_branches_use_authenticated_executor(
    self,
  ) -> None:
    executors = scope.load_executors()
    identities = {
      *(
        "retryable-reads/tests/unified/handshakeError.json::test["
          f"{index}]"
        for index in (*range(1, 5), *range(9, 13), *range(15, 31))
      ),
      *(
        "retryable-writes/tests/unified/handshakeError.json::test["
          f"{index}]"
        for index in range(3, 21)
      ),
    }

    self.assertEqual(42, len(identities))

    for identity in identities:
      self.assertEqual(
        "live-authenticated-replicaset",
        executors[identity]["environment"],
      )

  def test_full_conformance_unions_pre_8_2_evidence_for_v10(self) -> None:
    workflow = (
      scope.ROOT / ".github" / "workflows" / "full-conformance.yml"
    ).read_text(encoding="utf-8")

    for primary, supplemental in (
      (
        "build/conformance/unified.json",
        "build/conformance/version-branches/unified-pre-8.2.json",
      ),
      (
        "build/conformance/unified-macos.json",
        "build/conformance/macos-version-branches/"
          "unified-macos-pre-8.2.json",
      ),
    ):
      command = (
        "python3 spec/v10/scope.py\n"
        "          --check\n"
        f"          --execution-report {primary}\n"
        f"          --execution-report {supplemental}"
      )
      self.assertIn(command, workflow)

  def test_encryption_branch_cannot_return_to_optional(self) -> None:
    capabilities = copy.deepcopy(scope.load_capabilities())
    identity = next(
      case_id
      for case_id, capability in capabilities.items()
      if capability["activity"] == "ADV-010"
      and scope._is_load_balanced_branch(capability)
    )
    capabilities[identity]["status"] = "deferred_unsupported"

    with self.assertRaisesRegex(scope.ScopeError, "optional-suite owner"):
      scope.classify(
        scope.load_cases(),
        scope.load_requirements(),
        capabilities,
        scope.load_executors(),
        scope.load_activities(),
      )

  def test_closure_cases_use_the_load_balanced_executor(self) -> None:
    generated = scope.generate()
    executors = scope.load_executors()

    self.assertTrue(scope.CLOSURE_EXECUTORS <= set(generated["exact_unified_cases"]))

    for identity in scope.CLOSURE_EXECUTORS:
      self.assertEqual("CON-010", executors[identity]["activity"])
      self.assertEqual("live-load-balanced", executors[identity]["environment"])

  def test_upstream_skip_and_terminal_unsupported_are_exact(self) -> None:
    generated = scope.generate()
    skipped = generated["dedicated_cases"][scope.UPSTREAM_SKIP]

    self.assertEqual("excluded_scope", skipped["status"])
    self.assertIn("skipReason", skipped["reason"])
    expected = dict(scope.TERMINAL_UNSUPPORTED)
    expected.update({
      identity: capability["activity"]
      for identity, capability in scope.load_capabilities().items()
      if capability["status"] == "unsupported"
      and scope._is_load_balanced_branch(capability)
    })
    self.assertEqual(246, len(expected))
    self.assertEqual(
      expected,
      {
        identity: evidence["activity"]
        for identity, evidence in generated["terminal_unsupported"].items()
      },
    )


if __name__ == "__main__":
  unittest.main()
