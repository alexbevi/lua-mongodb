from __future__ import annotations

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "generate_stringprep_tables.py"
SPEC = importlib.util.spec_from_file_location("generate_stringprep_tables", MODULE_PATH)
assert SPEC and SPEC.loader
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


class GeneratedStringprepTests(unittest.TestCase):
  def test_hangul_composition_is_explicitly_version_independent(self) -> None:
    class Python314UnicodeData:
      def decomposition(self, _character: str) -> str:
        raise AssertionError("Hangul must bypass version-dependent UCD data")

      def normalize(self, _form: str, _value: str) -> str:
        raise AssertionError("Hangul must bypass version-dependent UCD data")

    with mock.patch.object(generator, "UCD", Python314UnicodeData()):
      self.assertIsNone(generator.composition_entry(generator.HANGUL_FIRST))

  def test_check_reports_drift_without_rewriting(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      output = Path(temporary) / "stringprep_tables.lua"
      output.write_text("stale\n", encoding="utf-8")
      errors = io.StringIO()

      with mock.patch.object(
        generator, "render_tables", return_value="generated\n",
      ), contextlib.redirect_stderr(errors):
        result = generator.main(["--check", "--output", str(output)])

      self.assertEqual(1, result)
      self.assertEqual("stale\n", output.read_text(encoding="utf-8"))
      self.assertIn("generated Stringprep tables are stale", errors.getvalue())

  def test_regeneration_and_matching_check_are_deterministic(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      output = Path(temporary) / "stringprep_tables.lua"

      with mock.patch.object(
        generator, "render_tables", return_value="generated\n",
      ):
        self.assertEqual(0, generator.main(["--output", str(output)]))
        first = output.read_bytes()
        self.assertEqual(0, generator.main(["--output", str(output)]))
        self.assertEqual(first, output.read_bytes())
        self.assertEqual(
          0,
          generator.main(["--check", "--output", str(output)]),
        )

  def test_committed_table_matches_generated_unicode_data(self) -> None:
    self.assertEqual(0, generator.main(["--check"]))

  def test_fast_gate_runs_the_read_only_artifact_check(self) -> None:
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    runtime_gate = next(
      line for line in makefile.splitlines()
      if line.startswith("check-fast-runtime:")
    )

    self.assertIn("test-generated", runtime_gate)
    self.assertIn(
      '"$(PYTHON)" tools/generate_stringprep_tables.py --check',
      makefile,
    )


if __name__ == "__main__":
  unittest.main()
