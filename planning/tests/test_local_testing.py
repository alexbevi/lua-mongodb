from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = ROOT / "Makefile"


class LocalTestingTests(unittest.TestCase):
  def run_make(self, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
      ["make", *arguments], cwd=ROOT, text=True,
      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False,
    )

  def test_focus_requires_an_explicit_selector(self) -> None:
    result = self.run_make("test-focus")

    self.assertEqual(result.returncode, 2)
    self.assertIn("Set at least one FOCUS_ selector", result.stdout)

  def test_focus_runs_only_the_selected_python_test(self) -> None:
    result = self.run_make(
      "test-focus",
      "FOCUS_PYTHON=planning.tests.test_update_plan.JsonTests.test_missing_and_malformed_json_are_explained",
    )

    self.assertEqual(result.returncode, 0, result.stdout)
    self.assertIn("Ran 1 test", result.stdout)

  def test_unified_focus_rejects_a_selector_that_matches_nothing(self) -> None:
    result = subprocess.run(
      [
        "python3", "spec/unified/run.py", "--include",
        "this-selector-must-not-match-any-unified-test",
      ],
      cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
      check=False,
    )

    self.assertEqual(result.returncode, 2)
    self.assertIn("matched no tests", result.stdout)

  def test_github_actions_retains_the_authoritative_full_gate(self) -> None:
    workflow = (
      ROOT / ".github" / "workflows" / "full-conformance.yml"
    ).read_text(encoding="utf-8")

    self.assertIn("make check-fast test-coverage", workflow)
    self.assertIn("python3 spec/unified/run.py", workflow)

  def test_makefile_separates_fast_and_full_verification(self) -> None:
    makefile = MAKEFILE.read_text(encoding="utf-8")
    fast_gate = next(
      line for line in makefile.splitlines()
      if line.startswith("check-fast:")
    )
    runtime_gate = next(
      line for line in makefile.splitlines()
      if line.startswith("check-fast-runtime:")
    )

    self.assertIn("check: check-full", makefile)
    self.assertIn(
      "check-fast-runtime: test-unit test-integration test-unified-static",
      makefile,
    )
    self.assertIn("check-fast: check-fast-runtime test-complexity lint", makefile)
    self.assertIn(
      "check-full: check-fast test-unified-execution test-coverage",
      makefile,
    )
    self.assertIn("spec/v04/scope.py --check", makefile)
    self.assertIn("spec/v05/scope.py --check", makefile)
    self.assertIn("spec/v06/scope.py --check", makefile)
    self.assertIn("spec/v07/scope.py --check", makefile)
    self.assertIn('--execution-report "$(UNIFIED_REPORT)"', makefile)
    self.assertIn(
      '--execution-report "$(V04_SUPPLEMENTAL_REPORT)"',
      makefile,
    )
    self.assertEqual(
      4,
      makefile.count('--execution-report "$(V04_SUPPLEMENTAL_REPORT)"'),
      "v0.4 through v0.7 must consume supplemental version evidence",
    )
    self.assertIn("test-package", runtime_gate)
    self.assertIn("test-complexity", fast_gate)
    self.assertEqual(
      makefile.count("spec/unified/validate_fixtures.py --lua"),
      1,
      "the composed unified gates must not validate every fixture twice",
    )
    self.assertIn("update-spec-artifacts: check-python", makefile)
    self.assertIn(
      '"$(PYTHON)" planning/update_spec_artifacts.py',
      makefile,
    )


if __name__ == "__main__":
  unittest.main()
