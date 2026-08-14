#!/usr/bin/env python3
"""Ratchet production Lua cyclomatic complexity from Luacheck's report."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


SCHEMA_VERSION = 1
DEFAULT_MAXIMUM_NEW_COMPLEXITY = 40
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = ROOT / "spec/quality/lua-complexity-baseline.json"
FUNCTION_WARNING = re.compile(
  r"^(?P<path>.*?\.lua):(?P<line>\d+):\d+(?:-\d+)?: \(W561\) "
  r"cyclomatic complexity of (?:function|method) '(?P<name>[^']+)' "
  r"is too high \((?P<score>\d+) > 1\)$"
)
MAIN_WARNING = re.compile(
  r"^(?P<path>.*?\.lua):(?P<line>\d+):\d+(?:-\d+)?: \(W561\) "
  r"cyclomatic complexity of main chunk is too high "
  r"\((?P<score>\d+) > 1\)$"
)
ANONYMOUS_WARNING = re.compile(
  r"^(?P<path>.*?\.lua):(?P<line>\d+):\d+(?:-\d+)?: \(W561\) "
  r"cyclomatic complexity of function is too high "
  r"\((?P<score>\d+) > 1\)$"
)


class ComplexityError(ValueError):
  """Raised when the Luacheck report or baseline is invalid."""


@dataclass(frozen=True)
class Metric:
  path: str
  name: str
  line: int
  score: int

  @property
  def key(self) -> tuple[str, str]:
    return self.path, self.name

  @property
  def identity(self) -> str:
    return f"{self.path}::{self.name}"


def parse_report(report: str) -> list[Metric]:
  metrics = []

  for line in report.splitlines():
    if "(W561)" not in line:
      continue

    matched = (
      FUNCTION_WARNING.match(line)
      or MAIN_WARNING.match(line)
      or ANONYMOUS_WARNING.match(line)
    )

    if matched is None:
      raise ComplexityError(f"cannot parse Luacheck complexity warning: {line}")

    values = matched.groupdict()
    metrics.append(Metric(
      path=values["path"],
      name=(
        values.get("name")
        or ("<main>" if "main chunk" in line else f"<anonymous@{values['line']}>")
      ),
      line=int(values["line"]),
      score=int(values["score"]),
    ))

  metrics.sort(key=lambda metric: metric.key)
  keys = [metric.key for metric in metrics]

  if len(keys) != len(set(keys)):
    raise ComplexityError(
      "Luacheck reported duplicate function identities; name the functions "
      "uniquely before ratcheting them"
    )

  return metrics


def run_luacheck(root: Path, executable: str) -> list[Metric]:
  command = [
    executable,
    "--no-color",
    "--formatter", "plain",
    "--codes",
    "--ranges",
    "--only", "561",
    "--max-cyclomatic-complexity", "1",
    "src/mongodb",
  ]

  try:
    result = subprocess.run(
      command,
      cwd=root,
      text=True,
      stdout=subprocess.PIPE,
      stderr=subprocess.STDOUT,
      check=False,
    )
  except OSError as exc:
    raise ComplexityError(f"cannot run Luacheck executable {executable}: {exc}") from exc

  if result.returncode not in (0, 1):
    raise ComplexityError(
      f"Luacheck complexity report failed with exit {result.returncode}:\n"
      f"{result.stdout.strip()}"
    )

  return parse_report(result.stdout)


def load_baseline(path: Path) -> dict[str, Any]:
  try:
    baseline = json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise ComplexityError(f"cannot read complexity baseline {path}: {exc}") from exc

  if baseline.get("schema_version") != SCHEMA_VERSION:
    raise ComplexityError("unsupported Lua complexity baseline schema version")

  limit = baseline.get("maximum_new_complexity")

  if not isinstance(limit, int) or isinstance(limit, bool) or limit <= 1:
    raise ComplexityError("maximum_new_complexity must be an integer above 1")

  hotspots = baseline.get("hotspots")

  if not isinstance(hotspots, list):
    raise ComplexityError("complexity baseline hotspots must be an array")

  expected_order = sorted(
    hotspots,
    key=lambda hotspot: (hotspot.get("path", ""), hotspot.get("function", "")),
  )

  if hotspots != expected_order:
    raise ComplexityError("complexity baseline hotspots must be sorted by path and function")

  identities = set()

  for hotspot in hotspots:
    if not isinstance(hotspot, dict):
      raise ComplexityError("complexity baseline hotspot must be an object")

    path_value = hotspot.get("path")
    function = hotspot.get("function")
    score = hotspot.get("complexity")

    if not isinstance(path_value, str) or not path_value.startswith("src/mongodb/"):
      raise ComplexityError("complexity hotspot path must be below src/mongodb")

    if not isinstance(function, str) or not function:
      raise ComplexityError("complexity hotspot function must be a non-empty string")

    if not isinstance(score, int) or isinstance(score, bool) or score <= limit:
      raise ComplexityError(
        "complexity hotspot score must exceed maximum_new_complexity"
      )

    identity = path_value, function

    if identity in identities:
      raise ComplexityError(
        f"duplicate complexity hotspot {path_value}::{function}"
      )

    identities.add(identity)

  return baseline


def compare(baseline: dict[str, Any], metrics: list[Metric]) -> list[str]:
  limit = baseline["maximum_new_complexity"]
  expected = {
    (hotspot["path"], hotspot["function"]): hotspot["complexity"]
    for hotspot in baseline["hotspots"]
  }
  measured = {metric.key: metric for metric in metrics}
  issues = []

  for key in sorted(set(expected) | set(measured)):
    current = measured.get(key)
    baseline_score = expected.get(key)
    identity = "::".join(key)

    if baseline_score is None:
      if current is not None and current.score > limit:
        issues.append(
          f"new complexity hotspot {identity} at line {current.line} has "
          f"score {current.score} above limit {limit}"
        )
    elif current is None:
      issues.append(
        f"complexity baseline is stale for {identity}: function is no longer "
        "reported; update the baseline"
      )
    elif current.score > baseline_score:
      issues.append(
        f"complexity regression {identity} at line {current.line} has score "
        f"{current.score} above baseline {baseline_score}"
      )
    elif current.score < baseline_score:
      issues.append(
        f"complexity baseline is stale for {identity}: score fell from "
        f"{baseline_score} to {current.score}; update the baseline"
      )

  return issues


def generated_baseline(metrics: list[Metric], limit: int) -> dict[str, Any]:
  return {
    "schema_version": SCHEMA_VERSION,
    "maximum_new_complexity": limit,
    "hotspots": [
      {
        "path": metric.path,
        "function": metric.name,
        "complexity": metric.score,
      }
      for metric in metrics if metric.score > limit
    ],
  }


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
  parser.add_argument("--luacheck", default=os.environ.get("LUACHECK", "luacheck"))
  parser.add_argument("--root", type=Path, default=ROOT)
  parser.add_argument(
    "--update",
    action="store_true",
    help="replace the baseline with current over-threshold functions",
  )
  return parser


def main(arguments: list[str] | None = None) -> int:
  options = build_parser().parse_args(arguments)

  try:
    metrics = run_luacheck(options.root, options.luacheck)

    if options.update:
      baseline = generated_baseline(metrics, DEFAULT_MAXIMUM_NEW_COMPLEXITY)
      options.baseline.parent.mkdir(parents=True, exist_ok=True)
      options.baseline.write_text(
        json.dumps(baseline, indent=2) + "\n",
        encoding="utf-8",
      )
      print(
        f"updated Lua complexity baseline with {len(baseline['hotspots'])} "
        f"hotspots above {baseline['maximum_new_complexity']}"
      )
      return 0

    baseline = load_baseline(options.baseline)
    issues = compare(baseline, metrics)
  except ComplexityError as exc:
    print(exc, file=sys.stderr)
    return 2

  if issues:
    for issue in issues:
      print(issue, file=sys.stderr)

    return 1

  maximum = max((metric.score for metric in metrics), default=1)
  print(
    f"Lua complexity baseline is current: {len(baseline['hotspots'])} "
    f"hotspots above {baseline['maximum_new_complexity']}; maximum {maximum}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
