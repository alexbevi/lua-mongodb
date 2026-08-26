import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
API = ROOT / "docs" / "API.md"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"


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

  def test_api_stability_policy_is_linked_and_explicit(self) -> None:
    readme = README.read_text(encoding="utf-8")
    api = API.read_text(encoding="utf-8")

    self.assertIn("[API stability policy](docs/API.md)", readme)

    for tier in (
      "Public",
      "Advanced extension",
      "Compatibility only",
      "Internal",
      "Test only",
    ):
      with self.subTest(tier=tier):
        self.assertIn(f"| {tier} |", api)

    self.assertIn("Patch releases preserve", api)
    self.assertIn("incompatible change", api)
    self.assertIn("minor release", api)
    self.assertIn("Internal and test-only modules carry no compatibility promise", api)

  def test_api_reference_names_every_supported_entry_point(self) -> None:
    api = API.read_text(encoding="utf-8")
    classification = json.loads(
      MODULE_CLASSIFICATION.read_text(encoding="utf-8")
    )

    for name, entry in classification["modules"].items():
      if entry["stability"] in ("public", "advanced-extension"):
        with self.subTest(module=name):
          self.assertIn(f"| `{name}` |", api)
      elif entry["stability"] == "compatibility-only":
        with self.subTest(module=name):
          self.assertIn(f"`{name}`", api)

    for name in classification["exports"]:
      with self.subTest(export=name):
        self.assertIn(f"`{name}`", api)


if __name__ == "__main__":
  unittest.main()
