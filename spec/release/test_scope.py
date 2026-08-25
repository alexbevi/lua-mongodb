"""Contract tests for production-core release-scope classification."""

import unittest

from spec.release import scope


class ReleaseScopeTests(unittest.TestCase):
  def test_rejects_a_deferred_case_owned_by_the_ambiguous_release_checkpoint(self):
    cases = {
      "fixture.json::test[1]": {
        "activity": "REL-001",
        "reason": "awaits release closure",
        "status": "deferred_unsupported",
      },
    }
    activities = {
      "REL-001": {"milestone": "production-core-v1", "status": "in_progress"},
    }

    with self.assertRaisesRegex(
      scope.ScopeError,
      "ambiguous release owner REL-001",
    ):
      scope.classify(cases, activities)

  def test_checked_in_scope_has_only_concrete_release_gaps_and_exclusions(self):
    report = scope.generate()

    self.assertEqual(5524, report["total_cases"])
    self.assertEqual(
      report["statuses"]["deferred_unsupported"],
      sum(report["deferred_by_scope"].values()),
    )
    self.assertNotIn("REL-001", report["deferred_by_activity"])
    self.assertNotIn("REL-009", report["deferred_by_activity"])

  def test_rejects_an_unassigned_production_core_gap(self):
    cases = {
      "fixture.json::test[1]": {
        "activity": "REL-008",
        "reason": "security review",
        "status": "deferred_unsupported",
      },
    }
    activities = {
      "REL-008": {"milestone": "production-core-v1", "status": "pending"},
    }

    with self.assertRaisesRegex(
      scope.ScopeError,
      "invalid production-core release owner REL-008",
    ):
      scope.classify(cases, activities)

  def test_rejects_an_additional_exclusion_without_a_capability_reason(self):
    cases = {
      "fixture.json::test[1]": {
        "activity": "ADV-999",
        "reason": "later",
        "status": "deferred_unsupported",
      },
    }
    activities = {
      "ADV-999": {"milestone": "additional", "status": "pending"},
    }

    with self.assertRaisesRegex(
      scope.ScopeError,
      "additional owner has no scope reason ADV-999",
    ):
      scope.classify(cases, activities)

  def test_accepts_a_reasoned_superseded_case_from_a_completed_activity(self):
    cases = {
      "fixture.json::test[1]": {
        "activity": "AUTH-020",
        "reason": "superseded by the current authentication specification",
        "status": "excluded_scope",
      },
    }
    activities = {
      "AUTH-020": {"milestone": "additional", "status": "completed"},
    }

    report = scope.classify(cases, activities)

    self.assertEqual({"excluded_scope": 1}, report["statuses"])
    self.assertEqual({}, report["deferred_by_activity"])


if __name__ == "__main__":
  unittest.main()
