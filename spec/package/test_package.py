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
ROCKSPEC = ROOT / "mongodb-0.10.6-1.rockspec"
SMOKE = ROOT / "spec" / "package" / "smoke.lua"
COMPLETENESS = ROOT / "spec" / "package" / "completeness.lua"
SOURCE_ROOT = ROOT / "src" / "mongodb"
TEST_SUPPORT_ROOT = ROOT / "spec" / "support" / "mongodb"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"
SUPPORTED_API_CLASSES = {
  "public",
  "advanced-extension",
  "compatibility-only",
  "internal",
}


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


def runtime_version(lua: str) -> str:
  checked = run_command(
    [lua, "-e", "io.write((_VERSION:gsub('^Lua ', '')))"],
    cwd=ROOT,
  )

  if checked.returncode != 0:
    raise AssertionError(checked.stderr or checked.stdout)

  version = checked.stdout.strip()

  if version not in ("5.4", "5.5"):
    raise AssertionError(f"unsupported package-test Lua version: {version}")

  return version


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


def classification_document() -> dict[str, object]:
  document = json.loads(MODULE_CLASSIFICATION.read_text(encoding="utf-8"))

  if document.get("schema_version") != 2:
    raise AssertionError("unsupported module classification schema version")

  return document


def module_classification() -> dict[str, dict[str, str]]:
  return classification_document()["modules"]


def top_level_exports() -> set[str]:
  source = (SOURCE_ROOT / "init.lua").read_text(encoding="utf-8")
  table_body = source.split("local M = {", 1)[1].split("\n}", 1)[0]
  exports = set(re.findall(
    r"^  ([A-Za-z_][A-Za-z0-9_]*)\s*=",
    table_body,
    re.MULTILINE,
  ))
  exports.update(re.findall(r"^M\.([A-Za-z_][A-Za-z0-9_]*)\s*=", source, re.MULTILINE))
  return exports


def local_source_rockspec(directory: Path) -> Path:
  source_name = "lua-mongodb-0.10.6-1"
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
  def test_every_shipped_module_and_top_level_export_is_classified(self) -> None:
    document = classification_document()

    classified_modules = document["modules"]
    production_modules = expected_modules()
    test_only_modules = {
      name: path
      for name, path in discovered_unified_modules().items()
      if path.startswith("spec/support/")
    }

    self.assertEqual(
      set(production_modules) | set(test_only_modules),
      set(classified_modules),
    )

    for name, path in production_modules.items():
      with self.subTest(module=name):
        self.assertEqual({"path", "stability"}, set(classified_modules[name]))
        self.assertEqual(path, classified_modules[name]["path"])
        self.assertIn(classified_modules[name]["stability"], SUPPORTED_API_CLASSES)

    for name, path in test_only_modules.items():
      with self.subTest(module=name):
        self.assertEqual({"path", "stability"}, set(classified_modules[name]))
        self.assertEqual(path, classified_modules[name]["path"])
        self.assertEqual("test-only", classified_modules[name]["stability"])
        self.assertNotIn(name, rockspec_modules())

    classified_exports = document["exports"]
    self.assertEqual(top_level_exports(), set(classified_exports))

    for name, entry in classified_exports.items():
      with self.subTest(export=name):
        self.assertEqual({"stability"}, set(entry))
        self.assertIn(entry["stability"], SUPPORTED_API_CLASSES)

  def test_release_dependencies_support_declared_lua_runtimes(self) -> None:
    rockspec = ROCKSPEC.read_text(encoding="utf-8")
    runtime_dependencies = rockspec.split("dependencies = {", 1)[1].split("}", 1)[0]

    self.assertNotIn('"luaossl ', rockspec)
    self.assertNotIn('"lua-csnappy ', runtime_dependencies)
    self.assertNotIn('"lua-zstd ', runtime_dependencies)
    self.assertIn('"lua-csnappy == 0.1.5-2"', rockspec)
    self.assertIn('"lua-zstd == 0.2.0-1"', rockspec)

    for dependency in (
      '"getpid == 0.1.0-1"',
      '"lua-cryptorandom >= 0.0.6, < 0.1"',
      '"lua-zlib >= 1.4, < 1.5"',
      '"md5 >= 1.3, < 1.4"',
      '"sha1 >= 0.5, < 0.6"',
    ):
      with self.subTest(dependency=dependency):
        self.assertIn(dependency, rockspec)

    self.assertIn('"lua >= 5.4, < 5.6"', rockspec)
    self.assertIn('"copas >= 4.11, < 4.13"', runtime_dependencies)

  def test_release_metadata_declares_only_verified_platforms(self) -> None:
    rockspec = ROCKSPEC.read_text(encoding="utf-8")
    platforms = rockspec.split("supported_platforms = {", 1)[1].split("}", 1)[0]

    self.assertEqual(["linux", "macosx"], re.findall(r'"([^"]+)"', platforms))

  def test_unified_modules_follow_explicit_package_classification(self) -> None:
    classified = module_classification()
    discovered = discovered_unified_modules()

    self.assertEqual(
      discovered,
      {
        name: entry["path"]
        for name, entry in classified.items()
        if name.startswith("mongodb.unified.")
      },
    )

    packaged = rockspec_modules()

    for name, entry in classified.items():
      with self.subTest(module=name):
        if entry["stability"] == "test-only":
          self.assertNotIn(name, packaged)
        else:
          self.assertIn(entry["stability"], SUPPORTED_API_CLASSES)
          self.assertEqual(entry["path"], packaged.get(name))

  def test_source_rock_separates_completeness_from_supported_api(
    self,
  ) -> None:
    lua = os.environ.get("LUA", "lua")
    luarocks = os.environ.get("LUAROCKS", "luarocks")
    lua_version = runtime_version(lua)

    with tempfile.TemporaryDirectory(prefix="lua-mongodb-package-") as directory:
      temporary = Path(directory)
      artifacts = temporary / "artifacts"
      install_tree = temporary / "tree"
      run_directory = temporary / "run"
      artifacts.mkdir()
      run_directory.mkdir()
      base = [luarocks, f"--lua-version={lua_version}"]
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
        f"{install_tree}/share/lua/{lua_version}/?.lua",
        f"{install_tree}/share/lua/{lua_version}/?/init.lua",
      ))
      environment["LUA_CPATH"] = f"{install_tree}/lib/lua/{lua_version}/?.so"
      environment["MONGODB_PACKAGE_TREE"] = str(install_tree)
      environment.pop("LUA_INIT", None)
      self.assertNotIn(str(ROOT), environment["LUA_PATH"])
      self.assertNotIn(str(ROOT), environment["LUA_CPATH"])

      classification = classification_document()
      documented_modules = sorted(
        name
        for name, entry in classification["modules"].items()
        if entry["stability"] in ("public", "advanced-extension")
      )
      documented_exports = sorted(classification["exports"])
      smoked = run_command(
        [
          lua,
          str(SMOKE),
          *documented_modules,
          "--exports",
          *documented_exports,
        ],
        cwd=run_directory,
        environment=environment,
      )
      self.assertEqual(0, smoked.returncode, smoked.stderr or smoked.stdout)
      self.assertIn("installed mongodb public API smoke passed", smoked.stdout)

      complete = run_command(
        [lua, str(COMPLETENESS), *sorted(rockspec_modules())],
        cwd=run_directory,
        environment=environment,
      )
      self.assertEqual(0, complete.returncode, complete.stderr or complete.stdout)
      self.assertIn("installed mongodb package completeness passed", complete.stdout)

      installed_lua = install_tree / "share" / "lua" / lua_version

      for name, entry in module_classification().items():
        if entry["stability"] == "test-only":
          module_path = installed_lua.joinpath(*name.split(".")).with_suffix(".lua")
          init_path = module_path.with_suffix("") / "init.lua"
          self.assertFalse(module_path.exists(), name)
          self.assertFalse(init_path.exists(), name)

    self.assertEqual(expected_modules(), rockspec_modules())


if __name__ == "__main__":
  unittest.main()
