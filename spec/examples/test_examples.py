from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from spec.package.test_package import local_source_rockspec


ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = ROOT / "examples"
PING = EXAMPLES / "00-connect-and-ping"
PACKAGES = EXAMPLES / "01-luarocks-package-explorer"
PINNED_IMAGE = (
  "mongodb/mongodb-community-server:8.2.12-ubuntu2204@sha256:"
  "ed7000edd775a8a7d1010618b72b2c71603efe2ca4f827b7f291110a696b4a41"
)
LIVE = os.environ.get("MONGODB_EXAMPLES_LIVE") == "1"


def run_command(
  command: list[str],
  *,
  cwd: Path,
  environment: dict[str, str] | None = None,
  timeout: int = 180,
) -> subprocess.CompletedProcess[str]:
  return subprocess.run(
    command,
    cwd=cwd,
    env=environment,
    capture_output=True,
    text=True,
    timeout=timeout,
  )


def rock_environment(tree: Path) -> dict[str, str]:
  environment = os.environ.copy()
  environment["LUA_PATH"] = ";".join((
    "./?.lua",
    "./?/init.lua",
    f"{tree}/share/lua/5.4/?.lua",
    f"{tree}/share/lua/5.4/?/init.lua",
  ))
  environment["LUA_CPATH"] = f"{tree}/lib/lua/5.4/?.so"
  environment.pop("LUA_INIT", None)
  return environment


def install_rock(mode: str, temporary: Path) -> tuple[Path, dict[str, str]]:
  luarocks = os.environ.get("LUAROCKS", "luarocks")
  tree = temporary / f"tree-{mode}"
  run_directory = temporary / f"run-{mode}"
  run_directory.mkdir()
  command = [luarocks, "--lua-version=5.4", f"--tree={tree}", "install"]

  if mode == "public":
    command.extend(["mongodb", "--deps-mode=one"])
  elif mode == "source":
    artifacts = temporary / "artifacts"
    artifacts.mkdir(exist_ok=True)
    rockspec = local_source_rockspec(artifacts)
    packed = run_command(
      [luarocks, "--lua-version=5.4", "pack", str(rockspec)],
      cwd=artifacts,
    )

    if packed.returncode != 0:
      raise AssertionError(packed.stderr or packed.stdout)

    rocks = list(artifacts.glob("mongodb-*.src.rock"))

    if len(rocks) != 1:
      raise AssertionError(f"expected one source rock, found {len(rocks)}")

    command.extend([str(rocks[0]), "--deps-mode=one"])
  else:
    raise AssertionError(f"unknown example rock mode: {mode}")

  for name in ("OPENSSL_DIR", "CRYPTO_DIR"):
    if os.environ.get(name):
      command.append(f"{name}={os.environ[name]}")

  installed = run_command(command, cwd=run_directory)

  if installed.returncode != 0:
    raise AssertionError(installed.stderr or installed.stdout)

  return tree, rock_environment(tree)


def assert_installed_rock(
  case: unittest.TestCase,
  tree: Path,
  environment: dict[str, str],
) -> None:
  lua = os.environ.get("LUA", "lua")
  script = (
    "local p=assert(package.searchpath('mongodb', package.path));"
    f"assert(p:sub(1,{len(str(tree))})=={str(tree)!r});"
    "local v=require('mongodb')._VERSION;"
    "local a,b,c=v:match('^(%d+)%.(%d+)%.(%d+)$');"
    "assert(a and (tonumber(a)>0 or tonumber(b)>=5),"
    "'mongodb 0.5.0 or later is required');"
    "print(v)"
  )
  checked = run_command(
    [lua, "-e", script],
    cwd=tree,
    environment=environment,
  )
  case.assertEqual(0, checked.returncode, checked.stderr or checked.stdout)
  case.assertRegex(checked.stdout.strip(), r"^\d+\.\d+\.\d+$")


class ConnectAndPingTests(unittest.TestCase):
  def test_required_artifacts_and_catalog_links(self) -> None:
    for relative in (
      "README.md",
      "main.lua",
      ".env.example",
      "expected-output.txt",
      "docker-compose.yml",
    ):
      self.assertTrue((PING / relative).is_file(), relative)

    examples_readme = (EXAMPLES / "README.md").read_text(encoding="utf-8")
    root_readme = (ROOT / "README.md").read_text(encoding="utf-8")
    self.assertIn("00-connect-and-ping", examples_readme)
    self.assertIn("examples/README.md", root_readme)

  def test_program_uses_only_the_installed_public_module(self) -> None:
    source = (PING / "main.lua").read_text(encoding="utf-8")
    self.assertIn('require("mongodb")', source)
    self.assertIn("mongodb.run", source)
    self.assertIn('os.getenv("MONGODB_URI")', source)
    self.assertIn("client:close", source)
    self.assertNotIn("package.path", source)
    self.assertNotIn("../src", source)

  def test_environment_compose_output_and_instructions_are_reproducible(
    self,
  ) -> None:
    environment = (PING / ".env.example").read_text(encoding="utf-8")
    compose = (PING / "docker-compose.yml").read_text(encoding="utf-8")
    expected = (PING / "expected-output.txt").read_text(encoding="utf-8")
    readme = (PING / "README.md").read_text(encoding="utf-8")

    self.assertEqual(
      "MONGODB_URI=mongodb://127.0.0.1:27017/lua_examples_ping\n",
      environment,
    )
    self.assertIn(PINNED_IMAGE, compose)
    self.assertEqual(
      "MongoDB driver 0.5.0 or later loaded from LuaRocks\n"
      "Ping succeeded\n"
      "Client closed\n",
      expected,
    )

    for phrase in (
      "lua -v",
      "luarocks --lua-version=5.4 install mongodb",
      "docker compose up -d --wait",
      "export MONGODB_URI",
      "$env:MONGODB_URI",
      "docker compose down -v",
      "expected-output.txt",
    ):
      self.assertIn(phrase, readme)

  @unittest.skipUnless(LIVE, "set MONGODB_EXAMPLES_LIVE=1 for live examples")
  def test_live_example_uses_public_and_source_rock_installations(self) -> None:
    lua = os.environ.get("LUA", "lua")
    compose = os.environ.get("DOCKER", "docker")
    project = "lua-mongodb-example-ping"
    uri = os.environ.get("MONGODB_EXAMPLES_URI")

    if uri is None:
      up = run_command(
        [compose, "compose", "-p", project, "up", "-d", "--wait"],
        cwd=PING,
        timeout=120,
      )
      self.assertEqual(0, up.returncode, up.stderr or up.stdout)
      uri = "mongodb://127.0.0.1:27017/lua_examples_ping"

    try:
      with tempfile.TemporaryDirectory(
        prefix="lua-mongodb-examples-"
      ) as directory:
        temporary = Path(directory)

        for mode in ("public", "source"):
          with self.subTest(mode=mode):
            tree, environment = install_rock(mode, temporary)
            environment["MONGODB_URI"] = uri
            assert_installed_rock(self, tree, environment)
            executed = run_command(
              [lua, "main.lua"],
              cwd=PING,
              environment=environment,
            )
            self.assertEqual(
              0,
              executed.returncode,
              executed.stderr or executed.stdout,
            )
            self.assertEqual(
              (PING / "expected-output.txt").read_text(encoding="utf-8"),
              executed.stdout,
            )
    finally:
      if os.environ.get("MONGODB_EXAMPLES_URI") is None:
        down = run_command(
          [compose, "compose", "-p", project, "down", "-v"],
          cwd=PING,
          timeout=120,
        )
        self.assertEqual(0, down.returncode, down.stderr or down.stdout)


class PackageExplorerSeedTests(unittest.TestCase):
  def test_seed_and_list_artifacts_are_self_contained(self) -> None:
    for relative in (
      "README.md",
      "main.lua",
      "seed.lua",
      "packages.lua",
      ".env.example",
      "expected-output.txt",
      "docker-compose.yml",
    ):
      self.assertTrue((PACKAGES / relative).is_file(), relative)

    catalog = (EXAMPLES / "README.md").read_text(encoding="utf-8")
    self.assertIn(
      "[LuaRocks package explorer](01-luarocks-package-explorer/README.md)",
      catalog,
    )

  def test_fixture_models_eight_packages_with_ordered_bson_values(self) -> None:
    source = (PACKAGES / "packages.lua").read_text(encoding="utf-8")
    self.assertEqual(8, source.count('{ "name",'))
    self.assertIn("bson.document", source)
    self.assertIn("bson.array", source)
    self.assertNotIn("http", source.lower())
    self.assertNotIn("luarocks.org", source.lower())

  def test_seed_list_environment_and_output_are_deterministic(self) -> None:
    seed = (PACKAGES / "seed.lua").read_text(encoding="utf-8")
    main = (PACKAGES / "main.lua").read_text(encoding="utf-8")
    environment = (PACKAGES / ".env.example").read_text(encoding="utf-8")
    compose = (PACKAGES / "docker-compose.yml").read_text(encoding="utf-8")
    expected = (PACKAGES / "expected-output.txt").read_text(encoding="utf-8")

    self.assertIn("create_index", seed)
    self.assertIn("delete_many", seed)
    self.assertIn("insert_many", seed)
    self.assertIn("package_name_unique", seed)
    self.assertIn("sort", main)
    self.assertNotIn("package.path", seed + main)
    self.assertEqual(
      "MONGODB_URI=mongodb://127.0.0.1:27018/lua_examples_packages\n",
      environment,
    )
    self.assertIn(PINNED_IMAGE, compose)
    self.assertTrue(expected.startswith(
      "Created unique index: package_name_unique\n"
      "Seeded 8 packages\n"
      "LuaRocks package catalog (8 packages)\n"
      "1. busted — 2.3.0-1\n"
      "2. copas — 4.11.0-1\n"
      "3. dkjson — 2.8-1\n"
      "4. lpeg — 1.1.0-2\n"
      "5. luacheck — 1.2.0-1\n"
      "6. luasec — 1.3.2-1\n"
      "7. luasocket — 3.1.0-1\n"
      "8. penlight — 1.14.0-3\n",
    ))

  @unittest.skipUnless(LIVE, "set MONGODB_EXAMPLES_LIVE=1 for live examples")
  def test_live_seed_and_list_use_public_and_source_rocks(self) -> None:
    lua = os.environ.get("LUA", "lua")
    compose = os.environ.get("DOCKER", "docker")
    project = "lua-mongodb-example-packages"
    uri = os.environ.get("MONGODB_EXAMPLES_URI")

    if uri is None:
      up = run_command(
        [compose, "compose", "-p", project, "up", "-d", "--wait"],
        cwd=PACKAGES,
        timeout=120,
      )
      self.assertEqual(0, up.returncode, up.stderr or up.stdout)
      uri = "mongodb://127.0.0.1:27018/lua_examples_packages"

    try:
      with tempfile.TemporaryDirectory(
        prefix="lua-mongodb-package-example-"
      ) as directory:
        temporary = Path(directory)

        for mode in ("public", "source"):
          with self.subTest(mode=mode):
            tree, environment = install_rock(mode, temporary)
            environment["MONGODB_URI"] = uri
            assert_installed_rock(self, tree, environment)
            output = ""

            for script in ("seed.lua", "main.lua"):
              executed = run_command(
                [lua, script],
                cwd=PACKAGES,
                environment=environment,
              )
              self.assertEqual(
                0,
                executed.returncode,
                executed.stderr or executed.stdout,
              )
              output += executed.stdout

            self.assertEqual(
              (PACKAGES / "expected-output.txt").read_text(encoding="utf-8"),
              output,
            )
    finally:
      if os.environ.get("MONGODB_EXAMPLES_URI") is None:
        down = run_command(
          [compose, "compose", "-p", project, "down", "-v"],
          cwd=PACKAGES,
          timeout=120,
        )
        self.assertEqual(0, down.returncode, down.stderr or down.stdout)


class PackageExplorerWorkflowTests(unittest.TestCase):
  def test_program_covers_lookup_queries_update_and_aggregation(self) -> None:
    source = (PACKAGES / "main.lua").read_text(encoding="utf-8")

    for phrase in (
      "find_one",
      '"versions.version"',
      '"labels"',
      "update_one",
      '"$set"',
      "aggregate",
      '"$unwind"',
      '"$group"',
      '"dependency_count"',
    ):
      self.assertIn(phrase, source)

  def test_workflow_output_is_complete_and_deterministic(self) -> None:
    expected = (PACKAGES / "expected-output.txt").read_text(encoding="utf-8")

    self.assertEqual(
      "Created unique index: package_name_unique\n"
      "Seeded 8 packages\n"
      "LuaRocks package catalog (8 packages)\n"
      "1. busted — 2.3.0-1\n"
      "2. copas — 4.11.0-1\n"
      "3. dkjson — 2.8-1\n"
      "4. lpeg — 1.1.0-2\n"
      "5. luacheck — 1.2.0-1\n"
      "6. luasec — 1.3.2-1\n"
      "7. luasocket — 3.1.0-1\n"
      "8. penlight — 1.14.0-3\n"
      "Lookup: copas — Coroutine-oriented portable asynchronous services\n"
      "Nested release query: luasec contains 1.3.2-1\n"
      "Networking label: copas, luasec, luasocket\n"
      "Updated copas: 4.11.0-1 -> 4.11.1-1 (1 modified)\n"
      "Dependency popularity:\n"
      "1. luafilesystem — 2 packages\n"
      "2. luasocket — 2 packages\n"
      "3. argparse — 1 package\n"
      "4. coxpcall — 1 package\n"
      "5. lua-term — 1 package\n"
      "6. penlight — 1 package\n",
      expected,
    )

    readme = (PACKAGES / "README.md").read_text(encoding="utf-8")

    for phrase in (
      "lookup",
      "nested release",
      "array membership",
      "aggregation pipeline",
      "nil, err",
    ):
      self.assertIn(phrase, readme.lower())


if __name__ == "__main__":
  unittest.main()
