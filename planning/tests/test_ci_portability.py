from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


class CiPortabilityTests(unittest.TestCase):
  def test_lua_inline_programs_do_not_use_recipe_continuations(self) -> None:
    commands = [
      line for line in MAKEFILE.read_text(encoding="utf-8").splitlines()
      if '"$(LUA)" -e' in line
    ]

    self.assertTrue(commands, "expected at least one Lua preflight command")

    for command in commands:
      self.assertFalse(
        command.rstrip().endswith("\\"),
        "a recipe continuation inside a quoted lua -e program is not portable",
      )

  def test_macos_openssl_is_configured_before_luarocks_dependencies(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    openssl = workflow.index("Configure OpenSSL on macOS")
    dependencies = workflow.index("Install development dependencies")

    self.assertLess(openssl, dependencies)
    self.assertIn("brew install openssl@3", workflow[openssl:dependencies])
    self.assertIn("OPENSSL_DIR=", workflow[openssl:dependencies])
    self.assertIn("CRYPTO_DIR=", workflow[openssl:dependencies])
    self.assertIn("GITHUB_ENV", workflow[openssl:dependencies])
    self.assertIn(
      'luarocks install --only-deps mongodb-scm-1.rockspec '
      'OPENSSL_DIR="$OPENSSL_DIR" CRYPTO_DIR="$CRYPTO_DIR"',
      workflow,
    )
    self.assertIn('if test -n "${OPENSSL_DIR:-}"; then', workflow)
    self.assertIn(
      "else\n            luarocks install --only-deps mongodb-scm-1.rockspec",
      workflow,
    )

  def test_portable_jobs_provision_unified_execution_tools(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    checks = workflow.index("Run authoritative full portable and loopback checks")

    self.assertLess(workflow.index("Install MongoDB test tools on Linux"), checks)
    self.assertLess(workflow.index("Install MongoDB test tools on macOS"), checks)
    self.assertIn("mongodb-org-server mongodb-mongosh", workflow)
    self.assertIn("brew trust mongodb/brew", workflow)
    self.assertIn("mongodb-community@8.0", workflow)

  def test_missing_compatibility_report_does_not_mask_primary_failure(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("if-no-files-found: warn", workflow)

  def test_artifact_upload_uses_node_24_action(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("uses: actions/upload-artifact@v7", workflow)
    self.assertNotIn("uses: actions/upload-artifact@v4", workflow)


if __name__ == "__main__":
  unittest.main()
