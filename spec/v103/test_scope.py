from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v103 import scope


class V103ScopeTests(unittest.TestCase):
  def test_generated_scope_closes_logging_foundation(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 234,
        "passed": 4,
        "planned": 230,
        "supported": 4,
      },
      generated["summary"],
    )
    self.assertEqual(
      {
        "foundation_requirements": 4,
        "standardized_cases": 230,
        "unified_cases": 52,
      },
      generated["evidence"],
    )

  def test_shared_requirements_have_exact_passing_evidence(self) -> None:
    generated = scope.generate()

    self.assertEqual(scope.FOUNDATION_REQUIREMENTS, {
      identity: (
        requirement["activity"],
        requirement["runner"],
        requirement["required_environment"],
      )
      for identity, requirement in generated["foundation_requirements"].items()
    })

  def test_standardized_cases_have_release_sized_owners(self) -> None:
    generated = scope.generate()

    self.assertEqual(scope.PLANNED_OWNER_COUNTS, generated["planned_by_activity"])
    self.assertNotIn("ADV-009", generated["planned_by_activity"])
    self.assertEqual(
      {
        "client-backpressure": 103,
        "command-logging-and-monitoring": 55,
        "connection-monitoring-and-pooling": 7,
        "open-telemetry": 24,
        "server-discovery-and-monitoring": 15,
        "server-selection": 11,
        "transactions": 9,
        "uri-options": 6,
      },
      generated["planned_by_suite"],
    )

  def test_stale_umbrella_or_foundation_evidence_fails_closure(self) -> None:
    cases = copy.deepcopy(scope.load_cases())
    requirements = copy.deepcopy(scope.load_requirements())
    capabilities = scope.load_capabilities()
    activities = scope.load_activities()
    case_identity = next(
      identity
      for identity, case in cases.items()
      if case["activity"] == "LOG-002"
    )

    cases[case_identity]["activity"] = "ADV-009"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(case_identity)):
      scope.classify(cases, requirements, capabilities, activities)

    cases = scope.load_cases()
    requirement_identity = "logging/logging.md::structured-events"
    requirements[requirement_identity]["runner"] = "pending:LOG-008"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(requirement_identity)):
      scope.classify(cases, requirements, capabilities, activities)


if __name__ == "__main__":
  unittest.main()
