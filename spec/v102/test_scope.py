from __future__ import annotations

import copy
import json
import re
import unittest

from spec.v102 import scope


class V102ScopeTests(unittest.TestCase):
  def test_generated_scope_closes_gssapi_surface(self) -> None:
    generated = scope.generate()
    committed = json.loads(scope.OUTPUT.read_text(encoding="utf-8"))

    self.assertEqual(committed, generated)
    self.assertEqual(
      {
        "classified": 21,
        "passed": 21,
        "planned": 0,
        "supported": 21,
      },
      generated["summary"],
    )
    self.assertEqual(
      {"configuration_cases": 11, "prose_requirements": 10},
      generated["evidence"],
    )
    self.assertEqual(
      {"auth": {"passed": 20}, "uri-options": {"passed": 1}},
      generated["suites"],
    )

  def test_every_gssapi_requirement_has_exact_passing_evidence(self) -> None:
    generated = scope.generate()

    self.assertEqual(scope.CONFIGURATION_CASES, set(generated["configuration_cases"]))
    self.assertEqual(scope.PROSE_REQUIREMENTS, {
      identity: (
        requirement["activity"],
        requirement["runner"],
        requirement["required_environment"],
      )
      for identity, requirement in generated["prose_requirements"].items()
    })

  def test_deferred_or_stale_gssapi_evidence_fails_closure(self) -> None:
    cases = scope.load_cases()
    requirements = copy.deepcopy(scope.load_requirements())
    activities = scope.load_activities()
    identity = "auth/auth.md::gssapi-sasl-conversation"

    requirements[identity]["status"] = "deferred_unsupported"
    requirements[identity]["activity"] = "AUTH-019"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, requirements, activities)

    requirements = copy.deepcopy(scope.load_requirements())
    requirements[identity]["runner"] = "spec/unit/future_gssapi_spec.lua"
    with self.assertRaisesRegex(scope.ScopeError, re.escape(identity)):
      scope.classify(cases, requirements, activities)

  def test_provider_claim_matches_the_recurring_live_environment(self) -> None:
    self.assertEqual(
      [
        {
          "lua": "5.4",
          "operating_system": "Ubuntu 24.04",
          "provider": "packaged system GSSAPI adapter",
          "required_environment": "ubuntu-24.04-lua-5.4-gssapi-live",
        }
      ],
      scope.generate()["provider_claims"],
    )


if __name__ == "__main__":
  unittest.main()
