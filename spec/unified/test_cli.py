"""Unit tests for unified fixture discovery and capability reporting."""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from spec.unified import run


class UnifiedCliTests(unittest.TestCase):
  def test_discovery_filters_and_rejects_unclassified_fixtures(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      source = Path(directory)
      fixture = source / "crud" / "tests" / "unified" / "find.json"
      fixture.parent.mkdir(parents=True)
      fixture.write_text("{}", encoding="utf-8")

      discovered = run.discover_fixtures(source, ["crud/**"])

      self.assertEqual(["crud/tests/unified/find.json"], discovered)
      with self.assertRaisesRegex(run.CapabilityError, "unclassified fixture"):
        run.classify_fixtures(discovered, {})

  def test_classification_rejects_stale_entries_and_empty_reasons(self) -> None:
    with self.assertRaisesRegex(run.CapabilityError, "undiscovered fixture"):
      run.classify_fixtures([], {
        "old/tests/unified/test.json": {
          "activity": "OLD-001",
          "reason": "old",
          "status": "deferred",
        },
      })

    with self.assertRaisesRegex(run.CapabilityError, "must have a reason"):
      run.classify_fixtures(["a/tests/unified/test.json"], {
        "a/tests/unified/test.json": {
          "activity": "A-001",
          "reason": "",
          "status": "deferred",
        },
      })

  def test_report_is_machine_readable_and_filters_classifications(self) -> None:
    classified = [
      {
        "activity": "A-001",
        "path": "a/tests/unified/test.json",
        "reason": "not ready",
        "status": "deferred",
      },
      {
        "activity": "B-001",
        "path": "b/tests/unified/test.json",
        "reason": "not ready",
        "status": "deferred",
      },
    ]
    selected = run.select_classifications(classified, ["a/**"])
    report = run.build_report(selected)

    self.assertEqual(1, report["summary"]["selected"])
    self.assertEqual(1, report["summary"]["deferred"])
    self.assertEqual("a/tests/unified/test.json", report["fixtures"][0]["path"])


if __name__ == "__main__":
  unittest.main()
