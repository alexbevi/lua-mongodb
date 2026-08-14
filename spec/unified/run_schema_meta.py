#!/usr/bin/env python3
"""Run the pinned unified-format schema meta-tests with the Lua validator."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FORMAT_ROOT = (
  ROOT / "planning" / "specifications" / "source" / "unified-test-format"
)
SCHEMA = FORMAT_ROOT / "schema-1.28.json"
META_TESTS = FORMAT_ROOT / "tests"


def lua_string(value: str) -> str:
  encoded = json.dumps(value, ensure_ascii=True)

  if "\\u" in encoded:
    raise ValueError("schema runner only embeds ASCII fixture envelopes")

  return encoded


def encoded_file(path: Path) -> str:
  encoded = base64.b64encode(path.read_bytes()).decode("ascii")
  return lua_string(encoded)


def load_cases() -> list[tuple[str, bool, Path]]:
  cases: list[tuple[str, bool, Path]] = []

  for directory, expected in (
    ("valid-pass", True),
    ("valid-fail", True),
    ("invalid", False),
  ):
    for path in sorted((META_TESTS / directory).glob("*.json")):
      cases.append((directory, expected, path))

  return cases


def lua_program(cases: list[tuple[str, bool, Path]]) -> str:
  rows = []

  for directory, expected, path in cases:
    relative = str(path.relative_to(ROOT))
    rows.append("{%s,%s,%s}" % (
      lua_string(relative),
      "true" if expected else "false",
      encoded_file(path),
    ))

  return f'''package.path = "spec/support/?.lua;spec/support/?/init.lua;src/?.lua;src/?/init.lua;" .. package.path
local base64 = require("mongodb.bson.base64")
local json = require("mongodb.bson.json")
local schema = require("mongodb.unified.schema")

local schema_text = assert(base64.decode({encoded_file(SCHEMA)}))
local validator = assert(schema.compile(assert(json.decode(schema_text))))
local cases = {{
{",".join(rows)}
}}

for index, case in ipairs(cases) do
  local document = assert(json.decode(assert(base64.decode(case[3]))))
  local ok, err = validator:validate(document)

  if case[2] then
    assert(ok, "case index " .. index .. " rejected: " .. tostring(err))
  else
    assert(not ok, "case index " .. index .. " accepted")
    assert(err.details.path:sub(1, 1) == "$", "case index " .. index .. ": missing path")
  end
end

print(#cases .. " unified schema meta-fixtures passed")
'''


def explain_failure(output: str, cases: list[tuple[str, bool, Path]]) -> str:
  match = re.search(r"case index (\d+)", output)

  if not match:
    return output

  directory, _, path = cases[int(match.group(1)) - 1]
  return f"{output}\nfixture: {directory}/{path.name}"


def build_report(cases: list[tuple[str, bool, Path]], passed: bool) -> dict[str, object]:
  return {
    "report_version": 2,
    "summary": {
      "executed": len(cases) if passed else 0,
      "failed": 0 if passed else 1,
      "passed": len(cases) if passed else 0,
      "selected": len(cases),
    },
    "type": "meta_runner",
  }


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  parser.add_argument("--report", type=Path)
  arguments = parser.parse_args()
  cases = load_cases()
  process = subprocess.run(
    [arguments.lua, "-"],
    cwd=ROOT,
    env=os.environ.copy(),
    input=lua_program(cases),
    text=True,
    capture_output=True,
  )

  if process.returncode != 0:
    output = process.stdout + process.stderr
    if arguments.report:
      arguments.report.write_text(
        json.dumps(build_report(cases, False), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
      )
    print(explain_failure(output, cases), file=sys.stderr)
    return process.returncode

  if arguments.report:
    arguments.report.write_text(
      json.dumps(build_report(cases, True), indent=2, sort_keys=True) + "\n",
      encoding="utf-8",
    )

  print(process.stdout, end="")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
