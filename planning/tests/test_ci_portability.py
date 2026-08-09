from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
FULL_WORKFLOW = ROOT / ".github" / "workflows" / "full-conformance.yml"


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
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    linux = workflow[workflow.index("  linux:"):workflow.index("  macos:")]
    macos = workflow[workflow.index("  macos:"):workflow.index("  compatibility:")]

    self.assertLess(
      linux.index("Install MongoDB test tools on Linux"),
      linux.index("Run authoritative full portable and loopback checks"),
    )
    self.assertLess(
      macos.index("Install MongoDB test tools on macOS"),
      macos.index("Run authoritative full portable and loopback checks"),
    )
    self.assertIn("mongodb-org-server mongodb-mongosh", workflow)
    self.assertIn("brew trust mongodb/brew", workflow)
    self.assertIn("mongodb-community@8.0", workflow)

  def test_missing_compatibility_report_does_not_mask_primary_failure(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("if-no-files-found: warn", workflow)

  def test_artifact_upload_uses_node_24_action(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("uses: actions/upload-artifact@v7", workflow)
    self.assertNotIn("uses: actions/upload-artifact@v4", workflow)

  def test_fast_workflow_is_cancelable_and_omits_full_execution(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("name: CI Fast", workflow)
    self.assertIn("cancel-in-progress: true", workflow)
    self.assertIn("run: make check-fast", workflow)
    self.assertNotIn("make check-full", workflow)
    self.assertNotIn("Install MongoDB test tools", workflow)

  def test_full_workflow_is_manual_and_scheduled(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("workflow_dispatch:", workflow)
    self.assertIn("schedule:", workflow)
    self.assertIn('cron: "0 4 * * 1-6"', workflow)
    self.assertIn('cron: "0 4 * * 0"', workflow)
    self.assertIn("make check-full", workflow)
    self.assertIn("UNIFIED_REPORT=build/conformance/unified.json", workflow)

  def test_fast_compatibility_uses_only_boundary_rows(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("mongodb-7.0-standalone", workflow)
    self.assertIn("mongodb-8.2-replicaset", workflow)
    self.assertNotIn("mongodb-8.0-standalone", workflow)

  def test_full_compatibility_retains_every_matrix_row(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn('series: ["7.0", "8.0", "8.2"]', workflow)
    self.assertIn("topology: [standalone, replicaset]", workflow)


if __name__ == "__main__":
  unittest.main()
