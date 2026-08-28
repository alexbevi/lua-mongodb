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
        "unified_cases": 97,
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

  def test_command_logging_scope_is_closed(self) -> None:
    generated = scope.generate()

    self.assertEqual(
      {
        "cases": 65,
        "statuses": {
          "excluded_scope": 2,
          "passed": 63,
        },
      },
      generated["command_conformance"],
    )

  def test_server_selection_logging_scope_is_closed(self) -> None:
    generated = scope.generate()

    self.assertEqual(
      {
        "cases": 11,
        "statuses": {
          "passed": 11,
        },
      },
      generated["server_selection_conformance"],
    )

    cases = copy.deepcopy(scope.load_cases())
    identity = next(
      identity
      for identity in cases
      if identity.startswith(scope.SERVER_SELECTION_LOGGING_PREFIX)
    )
    cases[identity]["status"] = "deferred_unsupported"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(
        cases,
        scope.load_requirements(),
        scope.load_capabilities(),
        scope.load_activities(),
      )

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
