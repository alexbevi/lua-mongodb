#!/usr/bin/env python3
"""Regenerate artifacts derived from the pinned MongoDB specifications."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
from typing import Sequence


ROOT = Path(__file__).resolve().parent.parent
ARTIFACT_COMMANDS: tuple[tuple[str, ...], ...] = (
  ("spec/unified/update_capabilities.py",),
  ("spec/conformance/catalog.py",),
  ("spec/conformance/ledger.py",),
  ("spec/release/scope.py",),
  ("spec/v04/scope.py",),
  ("spec/v05/scope.py",),
  ("spec/v06/scope.py",),
  ("spec/v07/scope.py",),
  ("spec/v08/scope.py",),
  ("spec/v09/scope.py",),
  ("spec/v10/scope.py",),
  ("spec/v102/scope.py",),
  ("spec/v103/scope.py",),
  ("planning/update_readme_compatibility.py",),
  ("planning/update_plan.py", "refresh"),
)


def regenerate(
  commands: Sequence[Sequence[str]] = ARTIFACT_COMMANDS,
  root: Path = ROOT,
) -> int:
  for command in commands:
    result = subprocess.run([sys.executable, *command], cwd=root, check=False)
    if result.returncode != 0:
      print(f"artifact update stopped at {' '.join(command)}", file=sys.stderr)
      return result.returncode
  return 0


def main() -> int:
  result = regenerate()
  if result == 0:
    print("updated specification-derived artifacts")
  return result


if __name__ == "__main__":
  raise SystemExit(main())
