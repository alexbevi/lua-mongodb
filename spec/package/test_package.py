from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROCKSPEC = ROOT / "mongodb-0.4.0-1.rockspec"
SMOKE = ROOT / "spec" / "package" / "smoke.lua"
SOURCE_ROOT = ROOT / "src" / "mongodb"
TEST_SUPPORT_ROOT = ROOT / "spec" / "support" / "mongodb"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"


def run_command(
  command: list[str],
  *,
  cwd: Path,
  environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
  return subprocess.run(
    command,
    cwd=cwd,
    env=environment,
    text=True,
    capture_output=True,
  )


def expected_modules() -> dict[str, str]:
  modules = {}

  for path in sorted(SOURCE_ROOT.rglob("*.lua")):
    relative = path.relative_to(SOURCE_ROOT).with_suffix("")
    parts = list(relative.parts)

    if parts[-1] == "init":
      parts.pop()

    name = ".".join(["mongodb", *parts])
    modules[name] = path.relative_to(ROOT).as_posix()

  return modules


def rockspec_modules() -> dict[str, str]:
  modules = {}
  pattern = re.compile(
    r'^\s*(?:mongodb|\["(?P<name>[^"]+)"\])\s*=\s*"(?P<path>[^"]+)"'
  )

  for line in ROCKSPEC.read_text(encoding="utf-8").splitlines():
    match = pattern.match(line)

    if match:
      modules[match.group("name") or "mongodb"] = match.group("path")

  return modules


def module_name(path: Path, root: Path) -> str:
  relative = path.relative_to(root).with_suffix("")
  parts = list(relative.parts)

  if parts[-1] == "init":
    parts.pop()

  return ".".join(["mongodb", *parts])


def discovered_unified_modules() -> dict[str, str]:
  modules = {}

  for root in (SOURCE_ROOT, TEST_SUPPORT_ROOT):
    for path in sorted((root / "unified").glob("*.lua")):
      modules[module_name(path, root)] = path.relative_to(ROOT).as_posix()

  return modules


def module_classification() -> dict[str, dict[str, str]]:
  document = json.loads(MODULE_CLASSIFICATION.read_text(encoding="utf-8"))

  if document.get("schema_version") != 1:
    raise AssertionError("unsupported module classification schema version")

  return document["modules"]


def local_source_rockspec(directory: Path) -> Path:
  source_name = "lua-mongodb-0.4.0-1"
  archive = directory / f"{source_name}.tar.gz"

  with tarfile.open(archive, "w:gz") as package:
    for relative in ("LICENSE", "README.md", "src"):
      package.add(ROOT / relative, arcname=f"{source_name}/{relative}")

  source = (
    "source = {\n"
    f'  url = "file://{archive}",\n'
    f'  dir = "{source_name}",\n'
    "}"
  )
  rockspec = directory / ROCKSPEC.name
  contents, replacements = re.subn(
    r"source = \{.*?\n\}",
    source,
    ROCKSPEC.read_text(encoding="utf-8"),
    count=1,
    flags=re.DOTALL,
  )

  if replacements != 1:
    raise AssertionError("rockspec must contain exactly one source table")

  rockspec.write_text(contents, encoding="utf-8")
  return rockspec


class PackageTests(unittest.TestCase):
  def test_unified_modules_follow_explicit_package_classification(self) -> None:
    classified = module_classification()
    discovered = discovered_unified_modules()

    self.assertEqual(
      discovered,
      {name: entry["path"] for name, entry in classified.items()},
    )

    packaged = rockspec_modules()

    for name, entry in classified.items():
      with self.subTest(module=name):
        self.assertIn(entry["surface"], ("runtime", "test-only"))

        if entry["surface"] == "runtime":
          self.assertEqual(entry["path"], packaged.get(name))
        else:
          self.assertNotIn(name, packaged)

  def test_source_rock_installs_complete_public_api_without_workspace_paths(
    self,
  ) -> None:
    lua = os.environ.get("LUA", "lua")
    luarocks = os.environ.get("LUAROCKS", "luarocks")

    with tempfile.TemporaryDirectory(prefix="lua-mongodb-package-") as directory:
      temporary = Path(directory)
      artifacts = temporary / "artifacts"
      install_tree = temporary / "tree"
      run_directory = temporary / "run"
      artifacts.mkdir()
      run_directory.mkdir()
      base = [luarocks, "--lua-version=5.4"]
      package_rockspec = local_source_rockspec(artifacts)

      packed = run_command(
        [*base, "pack", str(package_rockspec)],
        cwd=artifacts,
      )
      self.assertEqual(0, packed.returncode, packed.stderr or packed.stdout)
      source_rocks = list(artifacts.glob("mongodb-*.src.rock"))
      self.assertEqual(1, len(source_rocks), packed.stdout)
      build_variables = [
        f"{name}={os.environ[name]}"
        for name in ("OPENSSL_DIR", "CRYPTO_DIR")
        if os.environ.get(name)
      ]

      installed = run_command(
        [
          *base,
          f"--tree={install_tree}",
          "install",
          str(source_rocks[0]),
          "--deps-mode=one",
          *build_variables,
        ],
        cwd=run_directory,
      )
      self.assertEqual(
        0,
        installed.returncode,
        installed.stderr or installed.stdout,
      )

      environment = os.environ.copy()
      environment["LUA_PATH"] = ";".join((
        f"{install_tree}/share/lua/5.4/?.lua",
        f"{install_tree}/share/lua/5.4/?/init.lua",
      ))
      environment["LUA_CPATH"] = f"{install_tree}/lib/lua/5.4/?.so"
      environment["MONGODB_PACKAGE_TREE"] = str(install_tree)
      environment.pop("LUA_INIT", None)
      self.assertNotIn(str(ROOT), environment["LUA_PATH"])
      self.assertNotIn(str(ROOT), environment["LUA_CPATH"])

      smoked = run_command(
        [lua, str(SMOKE)],
        cwd=run_directory,
        environment=environment,
      )
      self.assertEqual(0, smoked.returncode, smoked.stderr or smoked.stdout)
      self.assertIn("installed mongodb public API smoke passed", smoked.stdout)

      installed_lua = install_tree / "share" / "lua" / "5.4"

      for name, entry in module_classification().items():
        if entry["surface"] == "test-only":
          module_path = installed_lua.joinpath(*name.split(".")).with_suffix(".lua")
          init_path = module_path.with_suffix("") / "init.lua"
          self.assertFalse(module_path.exists(), name)
          self.assertFalse(init_path.exists(), name)

    self.assertEqual(expected_modules(), rockspec_modules())


if __name__ == "__main__":
  unittest.main()
