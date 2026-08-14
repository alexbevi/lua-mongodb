"""Contract tests for deterministic LuaRocks publication."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from spec.release import publish


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


class PublishTests(unittest.TestCase):
  def test_release_metadata_is_derived_from_the_rockspec(self) -> None:
    metadata = publish.release_metadata(ROOT / "mongodb-0.2.0-1.rockspec")

    self.assertEqual("mongodb", metadata.package)
    self.assertEqual("0.2.0", metadata.version)
    self.assertEqual("0.2.0-1", metadata.rockspec_version)
    self.assertEqual("v0.2.0", metadata.tag)
    self.assertEqual("mongodb-0.2.0-1.src.rock", metadata.source_rock)

  def test_release_metadata_rejects_a_mismatched_source_tag(self) -> None:
    with tempfile.TemporaryDirectory() as directory:
      rockspec = Path(directory) / "mongodb-1.2.3-1.rockspec"
      rockspec.write_text(
        'package = "mongodb"\n'
        'version = "1.2.3-1"\n'
        'source = { tag = "v1.2.2" }\n',
        encoding="utf-8",
      )

      with self.assertRaisesRegex(
        publish.PublishError,
        "source tag v1.2.2 does not match version 1.2.3",
      ):
        publish.release_metadata(rockspec)

  def test_full_conformance_requires_every_release_job_on_the_same_sha(
    self,
  ) -> None:
    jobs = [
      {"name": name, "conclusion": "success"}
      for name in publish.REQUIRED_FULL_JOBS
    ]
    runs = [{
      "conclusion": "success",
      "headSha": "abc123",
      "jobs": jobs,
    }]

    publish.require_full_conformance(runs, "abc123")

    jobs[-1]["conclusion"] = "skipped"
    with self.assertRaisesRegex(
      publish.PublishError,
      "does not contain every successful release job",
    ):
      publish.require_full_conformance(runs, "abc123")

    jobs[-1]["conclusion"] = "success"
    with self.assertRaisesRegex(
      publish.PublishError,
      "no successful Full Conformance run",
    ):
      publish.require_full_conformance(runs, "different")

  def test_full_conformance_cli_reads_gh_json(self) -> None:
    jobs = [
      {"name": name, "conclusion": "success"}
      for name in publish.REQUIRED_FULL_JOBS
    ]

    with tempfile.TemporaryDirectory() as directory:
      runs = Path(directory) / "runs.json"
      runs.write_text(json.dumps([{
        "conclusion": "success",
        "headSha": "abc123",
        "jobs": jobs,
      }]), encoding="utf-8")

      self.assertEqual(
        0,
        publish.main([
          "check-conformance",
          "--sha",
          "abc123",
          "--runs",
          str(runs),
        ]),
      )

  def test_workflow_separates_dry_run_from_guarded_publication(self) -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    self.assertIn("name: LuaRocks Release", workflow)
    self.assertIn("workflow_dispatch:", workflow)
    self.assertIn("release_commit:", workflow)
    self.assertIn("required: true", workflow)
    self.assertNotIn("push:\n    tags:", workflow)
    self.assertIn("default: false", workflow)
    self.assertIn("permissions:\n  contents: read", workflow)
    credential = workflow[
      workflow.index("  credential:"):workflow.index("  validate:")
    ]
    self.assertIn("secrets.LUAROCKS_API_KEY", credential)
    self.assertNotIn("actions/checkout", credential)
    self.assertIn("/api/1/bearer/status", credential)
    self.assertIn("if: inputs.publish", workflow)
    self.assertIn("contents: write", workflow)
    self.assertIn("secrets.LUAROCKS_API_KEY", workflow)
    self.assertIn("inputs.confirm_version", workflow)
    self.assertIn("inputs.release_commit", workflow)
    self.assertIn("git merge-base --is-ancestor", workflow)
    self.assertIn("ref: ${{ steps.commit.outputs.release_sha }}", workflow)
    self.assertIn("RELEASE_SHA", workflow)
    self.assertIn('test "$GITHUB_SHA" = "$(git rev-parse origin/main)"', workflow)
    self.assertIn("make rockspec test-package test-release-checklist", workflow)
    self.assertIn("check-conformance", workflow)
    self.assertIn("--temp-key=\"$LUAROCKS_API_KEY\"", workflow)
    self.assertNotIn("--force", workflow)
    self.assertNotIn("--api-key", workflow)
    self.assertIn("gh release create", workflow)
    self.assertIn("install mongodb \"$ROCKSPEC_VERSION\"", workflow)


if __name__ == "__main__":
  unittest.main()
