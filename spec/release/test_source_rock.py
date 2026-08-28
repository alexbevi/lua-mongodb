"""Contract tests for upload-safe source-rock construction."""

from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "spec" / "release" / "source_rock.py"
ROCKSPEC = ROOT / "mongodb-0.10.6-1.rockspec"


class SourceRockTests(unittest.TestCase):
  def test_builder_omits_reference_submodule_payloads(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      output = Path(directory) / "mongodb-0.10.6-1.src.rock"
      command = [
        sys.executable,
        str(BUILDER),
        "--repository",
        str(ROOT),
        "--commit",
        "HEAD",
        "--rockspec",
        str(ROCKSPEC),
        "--source-directory",
        "lua-mongodb",
        "--output",
        str(output),
      ]
      result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
      )

      self.assertEqual(0, result.returncode, result.stderr)
      self.assertLess(output.stat().st_size, 10 * 1024 * 1024)
      with zipfile.ZipFile(output) as source_rock:
        names = set(source_rock.namelist())

      self.assertIn(ROCKSPEC.name, names)
      self.assertIn("lua-mongodb/src/mongodb/gridfs.lua", names)
      self.assertFalse(
        any(
          name.startswith("lua-mongodb/planning/pymongo/")
          and name != "lua-mongodb/planning/pymongo/"
          for name in names
        )
      )

      second_output = Path(directory) / "second.src.rock"
      command[-1] = str(second_output)
      second_result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
      )
      self.assertEqual(0, second_result.returncode, second_result.stderr)
      self.assertEqual(output.read_bytes(), second_output.read_bytes())
      self.assertFalse(
        any(
          name.startswith("lua-mongodb/planning/specifications/")
          and name != "lua-mongodb/planning/specifications/"
          for name in names
        )
      )


if __name__ == "__main__":
  unittest.main()
