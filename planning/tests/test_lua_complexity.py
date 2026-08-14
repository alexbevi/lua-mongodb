from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "check_lua_complexity.py"
SPEC = importlib.util.spec_from_file_location("check_lua_complexity", MODULE_PATH)
assert SPEC and SPEC.loader
complexity = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = complexity
SPEC.loader.exec_module(complexity)


def metric(path: str, name: str, score: int, line: int = 1):
  return complexity.Metric(path=path, name=name, line=line, score=score)


def baseline(*entries: tuple[str, str, int]) -> dict:
  return {
    "schema_version": 1,
    "maximum_new_complexity": 40,
    "hotspots": [
      {"path": path, "function": name, "complexity": score}
      for path, name, score in entries
    ],
  }


class LuaComplexityTests(unittest.TestCase):
  def test_rejects_a_new_function_above_the_threshold(self) -> None:
    issues = complexity.compare(
      baseline(),
      [metric("src/mongodb/new.lua", "new_work", 41, line=7)],
    )

    self.assertEqual([
      "new complexity hotspot src/mongodb/new.lua::new_work at line 7 has "
      "score 41 above limit 40",
    ], issues)

  def test_rejects_an_existing_hotspot_regression(self) -> None:
    issues = complexity.compare(
      baseline(("src/mongodb/work.lua", "run", 50)),
      [metric("src/mongodb/work.lua", "run", 51, line=9)],
    )

    self.assertEqual([
      "complexity regression src/mongodb/work.lua::run at line 9 has score "
      "51 above baseline 50",
    ], issues)

  def test_requires_baseline_updates_after_reductions(self) -> None:
    issues = complexity.compare(
      baseline(("src/mongodb/work.lua", "run", 50)),
      [metric("src/mongodb/work.lua", "run", 39, line=9)],
    )

    self.assertEqual([
      "complexity baseline is stale for src/mongodb/work.lua::run: score "
      "fell from 50 to 39; update the baseline",
    ], issues)

  def test_parses_named_anonymous_and_main_functions(self) -> None:
    report = "\n".join((
      "src/mongodb/a.lua:4:1-9: (W561) cyclomatic complexity of function "
      "'parse' is too high (7 > 1)",
      "src/mongodb/b.lua:8:1-9: (W561) cyclomatic complexity of method "
      "'M.run' is too high (12 > 1)",
      "src/mongodb/c.lua:1:1-1: (W561) cyclomatic complexity of main chunk "
      "is too high (2 > 1)",
      "src/mongodb/d.lua:14:3-6: (W561) cyclomatic complexity of function "
      "is too high (5 > 1)",
    ))

    self.assertEqual([
      metric("src/mongodb/a.lua", "parse", 7, line=4),
      metric("src/mongodb/b.lua", "M.run", 12, line=8),
      metric("src/mongodb/c.lua", "<main>", 2, line=1),
      metric("src/mongodb/d.lua", "<anonymous@14>", 5, line=14),
    ], complexity.parse_report(report))

  def test_fast_gate_runs_the_complexity_ratchet(self) -> None:
    makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
    fast_gate = next(
      line for line in makefile.splitlines() if line.startswith("check-fast:")
    )

    self.assertIn("test-complexity", fast_gate)
    self.assertIn('"$(PYTHON)" tools/check_lua_complexity.py', makefile)


if __name__ == "__main__":
  unittest.main()
