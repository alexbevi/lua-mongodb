from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "update_references.py"
SPEC = importlib.util.spec_from_file_location("update_references", MODULE_PATH)
assert SPEC and SPEC.loader
update_references = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_references)


def git(directory: Path, *arguments: str) -> str:
  result = subprocess.run(
    ["git", "-C", str(directory), *arguments],
    check=True,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
  )
  return result.stdout.strip()


def make_checkout(root: Path) -> tuple[Path, str, str]:
  checkout = root / "source"
  checkout.mkdir()
  git(checkout, "init", "-b", "main")
  git(checkout, "config", "user.name", "Test")
  git(checkout, "config", "user.email", "test@example.invalid")
  (checkout / "landmark.py").write_text("class Landmark:\n  pass\n", encoding="utf-8")
  git(checkout, "add", "landmark.py")
  git(checkout, "commit", "-m", "first")
  first = git(checkout, "rev-parse", "HEAD")
  (checkout / "landmark.py").write_text(
    "class Landmark:\n  value = 1\n", encoding="utf-8",
  )
  git(checkout, "add", "landmark.py")
  git(checkout, "commit", "-m", "second")
  second = git(checkout, "rev-parse", "HEAD")
  git(checkout, "checkout", "--detach", first)
  return checkout, first, second


def write_plan(root: Path, first: str) -> Path:
  path = root / "plan.json"
  path.write_text(
    json.dumps({
      "references": {
        "source": {
          "path": "source",
          "url": "https://example.invalid/source.git",
          "commit": first,
          "mappings": [{
            "name": "landmark",
            "path": "landmark.py",
            "symbol": "Landmark",
          }],
        },
      },
    }),
    encoding="utf-8",
  )
  return path


class ReferenceUpdateTests(unittest.TestCase):
  def test_advance_updates_checkout_and_plan_pin(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      plan_path = write_plan(root, first)

      summary = update_references.advance_reference(
        "source",
        second,
        root=root,
        plan_path=plan_path,
        generator_commands=(),
      )

      self.assertEqual(second, git(checkout, "rev-parse", "HEAD"))
      plan = json.loads(plan_path.read_text(encoding="utf-8"))
      self.assertEqual(second, plan["references"]["source"]["commit"])
      self.assertEqual({"M": 1}, summary)

  def test_advance_rejects_dirty_or_drifted_checkout(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      plan_path = write_plan(root, first)
      (checkout / "untracked").write_text("dirty", encoding="utf-8")

      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "dirty"):
        update_references.advance_reference(
          "source", second, root=root, plan_path=plan_path, generator_commands=(),
        )

      (checkout / "untracked").unlink()
      git(checkout, "checkout", "--detach", second)
      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "expected"):
        update_references.advance_reference(
          "source", second, root=root, plan_path=plan_path, generator_commands=(),
        )

  def test_advance_requires_fast_forward_by_default(self) -> None:
    with tempfile.TemporaryDirectory() as temporary:
      root = Path(temporary)
      checkout, first, second = make_checkout(root)
      plan_path = write_plan(root, second)
      git(checkout, "checkout", "--detach", first)
      (checkout / "other.py").write_text("value = 1\n", encoding="utf-8")
      git(checkout, "add", "other.py")
      git(checkout, "commit", "-m", "other")
      divergent = git(checkout, "rev-parse", "HEAD")
      git(checkout, "checkout", "--detach", second)

      with self.assertRaisesRegex(update_references.ReferenceUpdateError, "descendant"):
        update_references.advance_reference(
          "source", divergent, root=root, plan_path=plan_path, generator_commands=(),
        )


if __name__ == "__main__":
  unittest.main()
