import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"


class ReadmeContentTests(unittest.TestCase):
  def test_load_balanced_support_is_current(self) -> None:
    readme = README.read_text(encoding="utf-8")

    self.assertIn("loadBalanced=true", readme)
    self.assertNotIn(
      "Load-balanced deployment execution remains outside the current scope",
      readme,
    )
    self.assertNotIn("The public surface currently includes", readme)

  def test_headings_use_sentence_case(self) -> None:
    readme = README.read_text(encoding="utf-8")

    for heading in (
      "# MongoDB Lua Driver",
      "## Building and Installing",
      "## Getting Started",
      "### URI Options",
      "### CRUD Operations",
      "### Change Streams",
      "### Bulk Operations",
      "### Generic Commands",
      "### Index Management",
      "#### Search Indexes",
    ):
      self.assertNotIn(heading, readme)

  def test_local_links_resolve(self) -> None:
    readme = README.read_text(encoding="utf-8")

    for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", readme):
      if "://" in target or target.startswith("#"):
        continue

      path = target.split("#", 1)[0]
      self.assertTrue((ROOT / path).exists(), target)


if __name__ == "__main__":
  unittest.main()
