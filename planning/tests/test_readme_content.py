import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
API = ROOT / "docs" / "API.md"
ARCHITECTURE = ROOT / "docs" / "ARCHITECTURE.md"
SECURITY = ROOT / "SECURITY.md"
CONTRIBUTING = ROOT / "CONTRIBUTING.md"
CHANGELOG = ROOT / "CHANGELOG.md"
MAKEFILE = ROOT / "Makefile"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"
DOCUMENTS = (README, API, ARCHITECTURE, SECURITY, CONTRIBUTING, CHANGELOG)


def markdown_links(document: Path) -> list[str]:
  contents = document.read_text(encoding="utf-8")
  return re.findall(r"\[[^]]+\]\(([^)]+)\)", contents)


def markdown_headings(document: Path) -> list[str]:
  contents = document.read_text(encoding="utf-8")
  return re.findall(r"(?m)^#{1,6} +(.+?)\s*$", contents)


class DocumentationStructureTests(unittest.TestCase):
  def test_local_links_resolve(self) -> None:
    for document in DOCUMENTS:
      for target in markdown_links(document):
        if "://" in target or target.startswith("#"):
          continue

        path = target.split("#", 1)[0]

        if not path:
          continue

        with self.subTest(document=document.name, target=target):
          self.assertTrue((document.parent / path).exists(), target)

  def test_readme_puts_usage_before_conformance_details(self) -> None:
    text = README.read_text(encoding="utf-8")
    headings = [
      text.index("## Getting started"),
      text.index("## MongoDB drivers specification compatibility"),
    ]
    self.assertEqual(headings, sorted(headings))

  def test_readme_examples_cover_distinct_authentication(self) -> None:
    text = README.read_text(encoding="utf-8")
    examples = text.split("## Examples", 1)[1]
    examples = examples.split(
      "## MongoDB drivers specification compatibility",
      1,
    )[0]

    for heading in (
      "### Transactions",
      "### Client bulk writes",
      "### Change streams",
      "### GridFS",
    ):
      with self.subTest(heading=heading):
        self.assertIn(heading, examples)

    for authentication in (
      "SCRAM",
      "MONGODB-X509",
      "MONGODB-OIDC",
      "MONGODB-AWS",
    ):
      with self.subTest(authentication=authentication):
        self.assertIn(authentication, examples)

    self.assertIn("compressors=zlib", examples)
    self.assertIn("compressors=zstd", examples)
    self.assertEqual(4, examples.count("--[["))

  def test_security_policy_has_a_private_reporting_route(self) -> None:
    policy = SECURITY.read_text(encoding="utf-8")

    self.assertIn(
      "https://github.com/alexbevi/lua-mongodb/security/advisories/new",
      policy,
    )
    self.assertNotIn("mailto:", policy.lower())

  def test_contributor_guide_names_existing_project_commands(self) -> None:
    guide = CONTRIBUTING.read_text(encoding="utf-8")
    makefile = MAKEFILE.read_text(encoding="utf-8")

    for target in (
      "test-focus",
      "test-architecture",
      "test-complexity",
      "test-compatibility-live",
      "check-fast-runtime",
      "check-fast",
      "check-full",
    ):
      with self.subTest(target=target):
        self.assertIn(f"make {target}", guide)
        self.assertRegex(makefile, rf"(?m)^{re.escape(target)}:")

    for script in (
      "planning/update_plan.py",
      "planning/update_readme_compatibility.py",
      "spec/conformance/catalog.py",
      "spec/conformance/ledger.py",
    ):
      with self.subTest(script=script):
        self.assertTrue((ROOT / script).is_file())

  def test_api_reference_has_expected_sections(self) -> None:
    headings = set(markdown_headings(API))

    for heading in (
      "API stability",
      "Supported module entry points",
      "Client and database handles",
      "Collection and administration APIs",
      "Cursor and change-stream APIs",
      "Session and transaction APIs",
      "Bulk, index-model, and GridFS APIs",
      "BSON API",
      "Structured errors",
      "Runtime API",
      "Pre-1.0 change policy",
    ):
      with self.subTest(heading=heading):
        self.assertIn(heading, headings)

  def test_api_reference_names_every_supported_entry_point(self) -> None:
    api = API.read_text(encoding="utf-8")
    classification = json.loads(
      MODULE_CLASSIFICATION.read_text(encoding="utf-8")
    )

    for name, entry in classification["modules"].items():
      if entry["stability"] in (
        "public",
        "advanced-extension",
        "compatibility-only",
      ):
        with self.subTest(module=name):
          self.assertIn(f"`{name}`", api)

    for name in classification["exports"]:
      with self.subTest(export=name):
        self.assertIn(f"`{name}`", api)

  def test_internal_session_methods_are_not_documented_as_public(self) -> None:
    api = API.read_text(encoding="utf-8")
    section = api.split("## Session and transaction APIs", 1)[1]
    section = section.split("## Bulk, index-model, and GridFS APIs", 1)[0]

    for method in (
      "mark_dirty",
      "pin_server",
      "pin_connection",
      "unpin_server",
      "unpin_connection",
      "get_pinned_server_address",
      "get_pinned_connection",
    ):
      with self.subTest(method=method):
        self.assertNotIn(f"session:{method}", section)


if __name__ == "__main__":
  unittest.main()
