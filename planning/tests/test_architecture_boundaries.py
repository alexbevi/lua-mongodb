from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "check_architecture.py"
SPEC = importlib.util.spec_from_file_location("check_architecture", MODULE_PATH)
assert SPEC and SPEC.loader
check_architecture = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = check_architecture
SPEC.loader.exec_module(check_architecture)


class ArchitectureBoundaryTests(unittest.TestCase):
  def source_tree(self, files: dict[str, str]) -> tempfile.TemporaryDirectory[str]:
    temporary = tempfile.TemporaryDirectory()
    root = Path(temporary.name)

    for relative, source in files.items():
      path = root / relative
      path.parent.mkdir(parents=True, exist_ok=True)
      path.write_text(source, encoding="utf-8")

    return temporary

  def test_reports_a_deterministic_require_cycle(self) -> None:
    with self.source_tree({
      "alpha.lua": 'local beta = require("mongodb.beta")\nreturn beta\n',
      "beta.lua": 'local alpha = require("mongodb.alpha")\nreturn alpha\n',
    }) as temporary:
      issues = check_architecture.check_source(Path(temporary))

    self.assertEqual([
      "dependency cycle: mongodb.alpha -> mongodb.beta -> mongodb.alpha",
    ], issues)

  def test_reports_runtime_owned_imports_and_globals_in_core(self) -> None:
    with self.source_tree({
      "core.lua": (
        'local socket = require("socket")\n'
        'local ssl = require("ssl")\n'
        'local digest = require("openssl.digest")\n'
        'local home = os.getenv("HOME")\n'
        'local file = io.open("facts", "rb")\n'
        "return { socket, ssl, digest, home, file }\n"
      ),
    }) as temporary:
      issues = check_architecture.check_source(Path(temporary))

    self.assertEqual([
      "core.lua:1: mongodb.core imports runtime-owned module 'socket'",
      "core.lua:2: mongodb.core imports runtime-owned module 'ssl'",
      "core.lua:3: mongodb.core imports runtime-owned module 'openssl.digest'",
      "core.lua:4: mongodb.core accesses runtime-owned global 'os.getenv'",
      "core.lua:5: mongodb.core accesses runtime-owned global 'io.open'",
    ], issues)

  def test_allows_runtime_adapters_to_own_platform_access(self) -> None:
    with self.source_tree({
      "runtime/adapter.lua": (
        'local socket = require("socket")\n'
        'local ssl = require("ssl")\n'
        'local digest = require("openssl.digest")\n'
        'local home = os.getenv("HOME")\n'
        'local file = io.open("facts", "rb")\n'
        "return { socket, ssl, digest, home, file }\n"
      ),
    }) as temporary:
      self.assertEqual([], check_architecture.check_source(Path(temporary)))

  def test_does_not_treat_a_runtime_name_prefix_as_the_boundary(self) -> None:
    with self.source_tree({
      "runtime_guard.lua": "return os.time()\n",
    }) as temporary:
      issues = check_architecture.check_source(Path(temporary))

    self.assertEqual([
      "runtime_guard.lua:1: mongodb.runtime_guard accesses runtime-owned global "
      "'os.time'",
    ], issues)

  def test_repository_production_graph_is_valid(self) -> None:
    root = Path(__file__).resolve().parents[2] / "src" / "mongodb"

    self.assertEqual([], check_architecture.check_source(root))


if __name__ == "__main__":
  unittest.main()
