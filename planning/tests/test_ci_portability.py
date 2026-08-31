from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = ROOT / "Makefile"
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
FULL_WORKFLOW = ROOT / ".github" / "workflows" / "full-conformance.yml"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
SPECIFICATIONS_ACTION = ROOT / ".github" / "actions" / "init-specifications" / "action.yml"
DEPENDABOT = ROOT / ".github" / "dependabot.yml"
WORKFLOWS = tuple(sorted((ROOT / ".github" / "workflows").glob("*.yml")))


REMOTE_ACTION = re.compile(
  r"^\s*uses:\s*(?P<action>[^\s#]+)(?:\s+#\s*(?P<version>\S+))?\s*$"
)
UPLOAD_ARTIFACT_PIN = (
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7"
)
DOWNLOAD_ARTIFACT_PIN = (
  "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8"
)


class CiPortabilityTests(unittest.TestCase):
  def test_jobs_initialize_only_the_references_they_use(self) -> None:
    fast = WORKFLOW.read_text(encoding="utf-8")
    full = FULL_WORKFLOW.read_text(encoding="utf-8")
    release = RELEASE_WORKFLOW.read_text(encoding="utf-8")
    action = SPECIFICATIONS_ACTION.read_text(encoding="utf-8")

    self.assertEqual(1, fast.count("submodules: recursive"))
    self.assertIn("  reference-integrity:", fast)
    self.assertIn("planning/update_plan.py check-references", fast)
    self.assertIn("uses: ./.github/actions/init-specifications", fast)
    for start, end in (
      ("  compatibility-smoke:", "  gssapi-live:"),
      ("  gssapi-live:", "  examples:"),
    ):
      job = fast[fast.index(start):fast.index(end)]
      self.assertNotIn("submodules:", job)
      self.assertNotIn("init-specifications", job)
    examples = fast[fast.index("  examples:"):]
    self.assertNotIn("submodules:", examples)
    self.assertNotIn("init-specifications", examples)

    self.assertNotIn("submodules: recursive", full)
    compatibility = full[full.index("  compatibility:"):]
    self.assertNotIn("init-specifications", compatibility)
    self.assertNotIn("submodules:", release)
    self.assertIn(
      "git submodule update --init --depth 1 -- planning/specifications",
      action,
    )

  def test_remote_actions_use_full_sha_pins_with_version_comments(self) -> None:
    for workflow in WORKFLOWS:
      for line_number, line in enumerate(
        workflow.read_text(encoding="utf-8").splitlines(),
        start=1,
      ):
        match = REMOTE_ACTION.match(line)

        if match is None or match.group("action").startswith("./"):
          continue

        action, separator, reference = match.group("action").rpartition("@")

        with self.subTest(workflow=workflow.name, line=line_number):
          self.assertTrue(separator, f"remote action has no ref: {action}")
          self.assertRegex(reference, r"^[0-9a-f]{40}$")
          self.assertRegex(match.group("version") or "", r"^v\d+(?:\.\d+)*$")

  def test_dependabot_tracks_github_actions_weekly(self) -> None:
    configuration = DEPENDABOT.read_text(encoding="utf-8")

    self.assertIn("version: 2", configuration)
    self.assertIn('package-ecosystem: "github-actions"', configuration)
    self.assertIn('directory: "/"', configuration)
    self.assertIn('interval: "weekly"', configuration)

  def test_portable_matrix_tests_both_supported_lua_versions(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    portable = workflow[
      workflow.index("  portable:"):workflow.index("  compatibility-smoke:")
    ]

    self.assertEqual(2, portable.count('lua-version: "5.4.9"'))
    self.assertEqual(2, portable.count('lua-version: "5.5.1"'))
    self.assertEqual(2, portable.count("verification: full"))
    self.assertEqual(2, portable.count("verification: runtime"))
    self.assertIn("Install Lua ${{ matrix.lua-version }}", portable)
    self.assertIn('luaVersion: "${{ matrix.lua-version }}"', portable)
    self.assertIn('luaRocksVersion: "3.13.0"', portable)
    self.assertIn("run: make check-fast-runtime", portable)
    self.assertIn("if: matrix.verification == 'runtime'", portable)
    self.assertNotIn("if: matrix.lua-version", portable)

  def test_portable_matrix_covers_every_declared_platform(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    portable = workflow[
      workflow.index("  portable:"):workflow.index("  compatibility-smoke:")
    ]

    self.assertEqual(2, portable.count("os: ubuntu-latest"))
    self.assertEqual(2, portable.count("os: macos-latest"))
    self.assertNotIn("windows-latest", workflow)

  def test_luacheck_runs_only_on_its_supported_lua_runtime(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    portable = workflow[
      workflow.index("  portable:"):workflow.index("  compatibility-smoke:")
    ]
    lint_step = portable[
      portable.index("Install Lua 5.4 lint tools"):
      portable.index("Run required fast verification")
    ]

    self.assertIn("if: matrix.verification == 'full'", lint_step)
    self.assertIn("luarocks install luacheck 1.2.0-1", lint_step)

  def test_every_workflow_uses_final_lua_5_4_patch(self) -> None:
    workflows = "\n".join(
      workflow.read_text(encoding="utf-8")
      for workflow in WORKFLOWS
    )

    self.assertNotIn("5.4.8", workflows)
    self.assertIn("5.4.9", workflows)
    self.assertIn("5.5.1", workflows)

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
    openssl = workflow.index("Configure native libraries on macOS")
    dependencies = workflow.index("Install development dependencies")

    self.assertLess(openssl, dependencies)
    self.assertIn("brew install openssl@3 zstd", workflow[openssl:dependencies])
    self.assertIn("OPENSSL_DIR=", workflow[openssl:dependencies])
    self.assertIn("CRYPTO_DIR=", workflow[openssl:dependencies])
    self.assertIn("ZSTD_DIR=", workflow[openssl:dependencies])
    self.assertIn("GITHUB_ENV", workflow[openssl:dependencies])
    self.assertIn(
      'luarocks install --only-deps mongodb-0.10.6-1.rockspec '
      'OPENSSL_DIR="$OPENSSL_DIR" CRYPTO_DIR="$CRYPTO_DIR"',
      workflow,
    )
    self.assertIn('if test -n "${OPENSSL_DIR:-}"; then', workflow)
    self.assertIn(
      "else\n            luarocks install --only-deps mongodb-0.10.6-1.rockspec",
      workflow,
    )

  def test_portable_jobs_provision_unified_execution_tools(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    linux = workflow[
      workflow.index("  linux-unified:"):workflow.index("  linux-aggregate:")
    ]
    macos = workflow[
      workflow.index("  macos-unified:"):workflow.index("  compatibility:")
    ]

    self.assertLess(
      linux.index("Install MongoDB test tools on Linux"),
      linux.index("Run deterministic unified shard"),
    )
    self.assertLess(
      macos.index("Install MongoDB test tools on macOS"),
      macos.index("Run deterministic macOS unified shard"),
    )
    self.assertIn("sudo apt-get install -y mongodb-mongosh", linux)
    self.assertIn("brew install mongosh", macos)
    self.assertIn("$RUNNER_TEMP/full-conformance-mongodb", linux)
    self.assertIn("$RUNNER_TEMP/full-conformance-mongodb", macos)
    self.assertIn('echo "$mongodb_dir/bin" >> "$GITHUB_PATH"', linux)
    self.assertIn('echo "$mongodb_dir/bin" >> "$GITHUB_PATH"', macos)

  def test_full_unified_pins_the_server_patch_while_compatibility_moves(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn('FULL_CONFORMANCE_MONGODB_VERSION: "8.2.0"', workflow)
    self.assertIn(
      'FULL_CONFORMANCE_LEGACY_MONGODB_VERSION: "8.0.16"',
      workflow,
    )
    self.assertIn(
      "mongodb-linux-x86_64-ubuntu2404-${FULL_CONFORMANCE_MONGODB_VERSION}.tgz",
      workflow,
    )
    self.assertIn(
      "mongodb-macos-${mongodb_arch}-${FULL_CONFORMANCE_MONGODB_VERSION}.tgz",
      workflow,
    )
    self.assertIn('series: ["7.0", "8.0", "8.2"]', workflow)

  def test_macos_declares_only_exact_timing_skip_policies(
    self,
  ) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    makefile = MAKEFILE.read_text(encoding="utf-8")
    macos = workflow[
      workflow.index("  macos-unified:"):workflow.index("  compatibility:")
    ]
    supplemental = macos[
      macos.index("  macos-version-branches:"):
      macos.index("  macos-aggregate:")
    ]

    authoritative = macos[
      macos.index("  macos-aggregate:"):
      macos.index("Upload authoritative macOS conformance evidence")
    ]

    self.assertNotIn("MONGODB_UNIFIED_RUN_TIMING_SENSITIVE_CSOT", supplemental)
    self.assertEqual(4, authoritative.count("--allow-macos-ci-timing-skips"))

    for index in (4, 5, 6):
      self.assertNotIn(
        "--include 'client-side-operations-timeout/tests/"
        f"change-streams.json::test?{index}?'",
        supplemental,
      )

    linux = workflow[:workflow.index("  macos-platform:")]
    self.assertNotIn("--allow-macos-ci-timing-skips", linux)
    self.assertIn("V05_SCOPE_ARGUMENTS ?=", makefile)
    self.assertEqual(3, makefile.count("V05_SCOPE_ARGUMENTS"))

  def test_weekly_macos_verification_is_focused_and_bounded(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    platform = workflow[
      workflow.index("  macos-platform:"):workflow.index("  macos-unified:")
    ]
    complete = workflow[
      workflow.index("  macos-unified:"):workflow.index("  compatibility:")
    ]

    self.assertIn("github.event.schedule == '0 4 * * 0'", platform)
    self.assertIn("inputs.run_macos", platform)
    self.assertIn("timeout-minutes: 30", platform)
    self.assertIn("make test-package", platform)
    self.assertIn("make test-focus", platform)
    self.assertIn("spec/integration/copas_tcp_spec.lua", platform)
    self.assertIn("spec/integration/copas_tls_spec.lua", platform)
    self.assertIn("spec/integration/dns_seedlist_spec.lua", platform)

    for identity in (
      "crud/tests/unified/aggregate-allowdiskuse.json::test?1?",
      "transactions/tests/unified/commit.json::test?1?",
      "transactions-convenient-api/tests/unified/callback-commits.json::test?1?",
    ):
      self.assertIn(identity, platform)

    self.assertIn("--report build/conformance/macos-platform.json", platform)
    self.assertNotIn("github.event.schedule", complete)
    self.assertIn("github.event_name == 'workflow_dispatch'", complete)
    self.assertIn("inputs.run_macos", complete)
    self.assertNotIn("make check-full", complete)

  def test_missing_compatibility_report_does_not_mask_primary_failure(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("if-no-files-found: warn", workflow)

  def test_artifact_upload_uses_node_24_action(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn(f"uses: {UPLOAD_ARTIFACT_PIN}", workflow)

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
    self.assertIn("macos-platform:", workflow)
    self.assertIn("macos-unified:", workflow)
    self.assertIn("macos-aggregate:", workflow)
    self.assertNotIn("make check-full", workflow)

  def test_full_conformance_certifies_exact_copas_4_12(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    profile = workflow[
      workflow.index("  copas-profile:"):workflow.index("  linux-quality:")
    ]

    self.assertIn('lua-version: ["5.4.9", "5.5.1"]', profile)
    self.assertIn('luaRocksVersion: "3.13.0"', profile)
    self.assertNotIn("\n    if:", profile)
    self.assertIn("luarocks install copas 4.12.0-1", profile)
    self.assertIn('require("copas")._VERSION == "Copas 4.12.0"', profile)
    self.assertIn("spec/unit/copas_runtime_spec.lua", profile)
    self.assertIn("spec/unit/runtime_copas_spec.lua", profile)
    self.assertIn("spec/unit/topology_spec.lua", profile)
    self.assertIn("spec/integration/copas_tcp_spec.lua", profile)
    self.assertIn("spec/integration/copas_tls_spec.lua", profile)
    self.assertIn("spec/integration/dns_polling_spec.lua", profile)
    self.assertIn("spec/integration/dns_seedlist_spec.lua", profile)
    self.assertIn("run: make test-package", profile)

  def test_fast_compatibility_uses_only_boundary_rows(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("mongodb-7.0-standalone", workflow)
    self.assertIn("mongodb-8.0-sharded", workflow)
    self.assertIn("mongodb-8.2-replicaset", workflow)
    self.assertNotIn("mongodb-8.0-standalone", workflow)

  def test_full_compatibility_retains_every_matrix_row(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn('series: ["7.0", "8.0", "8.2"]', workflow)
    self.assertIn("topology: [standalone, replicaset, sharded]", workflow)

  def test_linux_full_conformance_is_sharded_and_aggregated(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")

    self.assertIn('"$mongodb_dir/bin/mongos" --version', workflow)
    self.assertIn("shard: [0, 1, 2, 3]", workflow)
    self.assertIn("--shard-count 4", workflow)
    self.assertIn("--shard-index ${{ matrix.shard }}", workflow)
    self.assertIn("needs: [linux-unified, linux-version-branches]", workflow)
    self.assertIn(f"uses: {DOWNLOAD_ARTIFACT_PIN}", workflow)
    self.assertIn("--aggregate build/conformance/shards/*.json", workflow)
    self.assertIn("Validate exact v0.4 conformance evidence", workflow)
    self.assertIn("Validate exact v0.5 conformance evidence", workflow)
    self.assertIn("Validate exact v0.6 conformance evidence", workflow)
    self.assertIn("Validate exact v0.7 conformance evidence", workflow)
    self.assertIn("Validate exact v0.9 conformance evidence", workflow)
    self.assertIn(
      "Validate exact v0.10.2 GSSAPI conformance evidence",
      workflow,
    )
    self.assertIn(
      "Validate exact v0.10.6 standardized logging evidence",
      workflow,
    )
    self.assertIn(
      "change-streams-disambiguatedPaths.json::test?1?",
      workflow,
    )
    self.assertIn("--execution-report build/conformance/unified.json", workflow)
    self.assertIn(
      "--execution-report build/conformance/version-branches/"
      "unified-pre-8.2.json",
      workflow,
    )
    v05_evidence = workflow[
      workflow.index("Validate exact v0.5 conformance evidence"):
      workflow.index("Upload authoritative Linux conformance evidence")
    ]
    self.assertIn(
      "build/conformance/version-branches/unified-pre-8.2.json",
      v05_evidence,
    )
    self.assertIn("if-no-files-found: error", workflow)

  def test_full_conformance_runs_every_pre_8_2_v0_6_rawdata_branch(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    linux = workflow[
      workflow.index("  linux-version-branches:"):
      workflow.index("  linux-aggregate:")
    ]
    macos = workflow[
      workflow.index("  macos-version-branches:"):
      workflow.index("  macos-aggregate:")
    ]

    for job in (linux, macos):
      self.assertIn(
        "crud/tests/unified/count-rawdata.json::test?2?",
        job,
      )
      self.assertIn(
        "crud/tests/unified/db-aggregate-rawdata.json::test?2?",
        job,
      )

  def test_full_conformance_runs_every_pre_8_2_v0_7_rawdata_branch(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    linux = workflow[
      workflow.index("  linux-version-branches:"):
      workflow.index("  linux-aggregate:")
    ]
    macos = workflow[
      workflow.index("  macos-version-branches:"):
      workflow.index("  macos-aggregate:")
    ]
    branches = (
      "crud/tests/unified/client-bulkWrite-delete-rawdata.json::test?2?",
      "crud/tests/unified/client-bulkWrite-replaceOne-rawdata.json::test?2?",
      "crud/tests/unified/client-bulkWrite-update-rawdata.json::test?2?",
    )

    for job in (linux, macos):
      for branch in branches:
        self.assertIn(branch, job)

  def test_linux_runs_short_circuit_csot_as_focused_exact_evidence(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    linux = workflow[
      workflow.index("  linux-version-branches:"):
      workflow.index("  linux-aggregate:")
    ]
    focused_marker = "Run isolated timing-sensitive Linux CSOT evidence"
    branches_marker = "Run exact supplemental version branches"
    focused = linux[
      linux.index(focused_marker):linux.index(branches_marker)
    ]
    branches = linux[
      linux.index(branches_marker):linux.index("Upload pre-8.2 exact evidence")
    ]

    self.assertIn("MONGODB_UNIFIED_RUN_TIMING_SENSITIVE_CSOT=1", focused)
    self.assertIn(
      "client-side-operations-timeout/tests/command-execution.json::test?3?",
      focused,
    )
    self.assertIn(
      "--report build/conformance/unified-linux-timing-sensitive-csot.json",
      focused,
    )
    self.assertNotIn(
      "client-side-operations-timeout/tests/command-execution.json::test?3?",
      branches,
    )
    self.assertIn(
      "build/conformance/unified-linux-timing-sensitive-csot.json",
      linux[linux.index("Upload pre-8.2 exact evidence"):],
    )
    self.assertIn("for attempt in 1 2 3; do", focused)
    self.assertIn("exit 0", focused)
    self.assertIn("exit 1", focused)
    self.assertNotIn("continue-on-error", focused)

  def test_manual_macos_full_conformance_is_sharded_and_aggregated(self) -> None:
    workflow = FULL_WORKFLOW.read_text(encoding="utf-8")
    macos = workflow[
      workflow.index("  macos-unified:"):workflow.index("  compatibility:")
    ]
    unified = macos[:macos.index("  macos-version-branches:")]
    version_branches = macos[
      macos.index("  macos-version-branches:"):
      macos.index("  macos-aggregate:")
    ]
    aggregate = macos[macos.index("  macos-aggregate:"):]

    self.assertNotIn("\n  macos:\n", workflow)
    self.assertIn("shard: [0, 1, 2, 3]", unified)
    self.assertIn("timeout-minutes: 75", unified)
    self.assertIn("--shard-count 4", unified)
    self.assertIn("--shard-index ${{ matrix.shard }}", unified)
    self.assertIn("unified-macos-shard-${{ matrix.shard }}.json", unified)
    self.assertIn("timeout-minutes: 30", version_branches)
    self.assertIn("unified-macos-pre-8.2.json", version_branches)
    self.assertIn(
      "needs: [macos-unified, macos-version-branches]",
      aggregate,
    )
    self.assertIn("timeout-minutes: 10", aggregate)
    self.assertIn(f"uses: {DOWNLOAD_ARTIFACT_PIN}", aggregate)
    self.assertIn(
      "--aggregate build/conformance/macos-shards/*.json",
      aggregate,
    )
    self.assertIn("Validate exact macOS v0.4 conformance evidence", aggregate)
    self.assertIn("Validate exact macOS v0.5 conformance evidence", aggregate)
    self.assertIn("Validate exact macOS v0.6 conformance evidence", aggregate)
    self.assertIn("Validate exact macOS v0.7 conformance evidence", aggregate)
    self.assertIn("Validate exact macOS v0.9 conformance evidence", aggregate)
    self.assertIn(
      "Validate exact macOS v0.10.2 GSSAPI conformance evidence",
      aggregate,
    )
    self.assertIn(
      "Validate exact macOS v0.10.6 standardized logging evidence",
      aggregate,
    )
    self.assertIn("--allow-macos-ci-timing-skips", aggregate)
    self.assertIn("full-conformance-macos-${{ github.sha }}", aggregate)


if __name__ == "__main__":
  unittest.main()
