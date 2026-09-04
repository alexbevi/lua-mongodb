from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "update_spec_artifacts.py"
SPEC = importlib.util.spec_from_file_location("update_spec_artifacts", MODULE_PATH)
assert SPEC and SPEC.loader
update_spec_artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_spec_artifacts)


class ArtifactUpdateTests(unittest.TestCase):
  def test_regeneration_stops_at_the_first_failed_generator(self) -> None:
    commands = (("first.py",), ("second.py",), ("third.py",))
    results = (
      subprocess.CompletedProcess([], 0),
      subprocess.CompletedProcess([], 2),
    )

    with mock.patch.object(
      update_spec_artifacts.subprocess,
      "run",
      side_effect=results,
    ) as run:
      status = update_spec_artifacts.regenerate(commands)

    self.assertEqual(2, status)
    self.assertEqual(2, run.call_count)
    self.assertEqual("first.py", run.call_args_list[0].args[0][1])
    self.assertEqual("second.py", run.call_args_list[1].args[0][1])


if __name__ == "__main__":
  unittest.main()
