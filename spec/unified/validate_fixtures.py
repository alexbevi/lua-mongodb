#!/usr/bin/env python3
"""Parse and schema-validate pinned unified fixtures with the Lua driver."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from spec.unified import run  # noqa: E402


SCHEMA = (
  ROOT
  / "planning"
  / "specifications"
  / "source"
  / "unified-test-format"
  / "schema-1.28.json"
)
SUPPORTED_SCHEMA_VERSION = (1, 28, 0)


class ValidationError(ValueError):
  """Raised when a pinned fixture cannot enter the unified inventory."""


def lua_string(value: str) -> str:
  encoded = json.dumps(value, ensure_ascii=True)

  if "\\u" in encoded:
    raise ValidationError("Lua validation envelope must contain ASCII strings")

  return encoded


def encoded_file(path: Path) -> str:
  return lua_string(base64.b64encode(path.read_bytes()).decode("ascii"))


def lua_program(source: Path, paths: list[str]) -> str:
  rows = []

  for relative in paths:
    rows.append("{%s,%s}" % (
      lua_string(relative),
      encoded_file(source / relative),
    ))

  return f'''package.path = "spec/support/?.lua;spec/support/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path
local base64 = require("mongodb.bson.base64")
local json = require("mongodb.bson.json")
local schema = require("mongodb.unified.schema")

local schema_text = assert(base64.decode({encoded_file(SCHEMA)}))
local validator = assert(schema.compile(assert(json.decode(schema_text))))
local fixtures = {{
{','.join(rows)}
}}

local function version_supported(version)
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.?(%d*)$")

  if major == nil then
    return false
  end

  major = tonumber(major)
  minor = tonumber(minor)
  patch = patch == "" and 0 or tonumber(patch)
  return major == {SUPPORTED_SCHEMA_VERSION[0]}
    and (minor < {SUPPORTED_SCHEMA_VERSION[1]}
      or minor == {SUPPORTED_SCHEMA_VERSION[1]}
        and patch <= {SUPPORTED_SCHEMA_VERSION[2]})
end

for _, fixture in ipairs(fixtures) do
  local text = assert(base64.decode(fixture[2]))
  local document, parse_err = json.decode(text)
  assert(document, fixture[1] .. ": parse failed: " .. tostring(parse_err))

  local version = document:get("schemaVersion")
  assert(type(version) == "string", fixture[1] .. ": missing schemaVersion")
  assert(version_supported(version), fixture[1] .. ": incompatible schemaVersion " .. version)

  local valid, validation_err = validator:validate(document)
  assert(valid, fixture[1] .. ": schema validation failed: " .. tostring(validation_err))

  local description = document:get("description")
  local tests = document:get("tests")
  local path = base64.encode(fixture[1])
  io.write("F\\t", path, "\\t", base64.encode(description), "\\t", version, "\\t", #tests, "\\n")

  for _, test in tests:iter() do
    io.write("T\\t", path, "\\t", base64.encode(test:get("description")), "\\n")
  end
end
'''


def decode_field(value: str) -> str:
  return base64.b64decode(value, validate=True).decode("utf-8")


def parse_lua_inventory(output: str) -> list[dict[str, Any]]:
  fixtures: dict[str, dict[str, Any]] = {}
  order = []

  for line in output.splitlines():
    fields = line.split("\t")

    if fields[0] == "F" and len(fields) == 5:
      path = decode_field(fields[1])
      fixture = {
        "description": decode_field(fields[2]),
        "path": path,
        "schema_version": fields[3],
        "test_count": int(fields[4]),
        "tests": [],
      }
      fixtures[path] = fixture
      order.append(path)
    elif fields[0] == "T" and len(fields) == 3:
      path = decode_field(fields[1])

      if path not in fixtures:
        raise ValidationError(f"Lua inventory emitted a test before fixture {path}")

      fixtures[path]["tests"].append(decode_field(fields[2]))
    else:
      raise ValidationError(f"unexpected Lua inventory output: {line}")

  result = [fixtures[path] for path in order]

  for fixture in result:
    if fixture["test_count"] != len(fixture["tests"]):
      raise ValidationError(
        f"Lua inventory test count changed for {fixture['path']}"
      )

  return result


def validate_fixture_documents(
  source: Path,
  paths: list[str],
  lua: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
  process = subprocess.run(
    [lua, "-"],
    cwd=ROOT,
    env=os.environ.copy(),
    input=lua_program(source, paths),
    text=True,
    capture_output=True,
  )

  if process.returncode != 0:
    raise ValidationError((process.stdout + process.stderr).strip())

  fixtures = parse_lua_inventory(process.stdout)
  inventory = run.build_inventory_report(fixtures)
  files = inventory["summary"]["files"]
  tests = inventory["summary"]["tests"]
  schema_report = {
    "files": [
      {
        "path": fixture["path"],
        "schema_version": fixture["schema_version"],
        "status": "schema_valid",
        "tests": fixture["test_count"],
      }
      for fixture in fixtures
    ],
    "report_version": run.REPORT_VERSION,
    "summary": {
      "discovered": len(paths),
      "invalid_or_incompatible": 0,
      "parsed": files,
      "schema_valid": files,
      "tests": tests,
    },
    "supported_schema_version": ".".join(map(str, SUPPORTED_SCHEMA_VERSION)),
    "type": "schema_validation",
  }
  return schema_report, inventory


def write_report(report: dict[str, Any], destination: Path | None) -> None:
  if destination is not None:
    destination.write_text(
      json.dumps(report, indent=2, sort_keys=True) + "\n",
      encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--source", type=Path, default=run.DEFAULT_SOURCE)
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  parser.add_argument("--include", action="append")
  parser.add_argument("--schema-report", type=Path)
  parser.add_argument("--inventory-report", type=Path)
  arguments = parser.parse_args(argv)

  try:
    paths = run.discover_fixtures(arguments.source, arguments.include)

    if not paths:
      raise ValidationError("unified fixture discovery found no files")

    schema_report, inventory = validate_fixture_documents(
      arguments.source,
      paths,
      arguments.lua,
    )
    write_report(schema_report, arguments.schema_report)
    write_report(inventory, arguments.inventory_report)
  except (OSError, ValidationError, ValueError) as exc:
    print(f"unified validation: {exc}", file=sys.stderr)
    return 2

  summary = schema_report["summary"]
  print(
    f"unified validation: {summary['schema_valid']}/{summary['discovered']} files "
    f"parsed and schema-valid; {summary['tests']} tests inventoried"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
