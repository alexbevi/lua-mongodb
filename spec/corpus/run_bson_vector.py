#!/usr/bin/env python3
"""Run pinned BSON binary vector fixtures against the public Lua API."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CORPUS = (
  ROOT / "planning" / "specifications" / "source"
  / "bson-binary-vector" / "tests"
)


def lua_string(value: str) -> str:
  return json.dumps(value, ensure_ascii=True)


def lua_number(value: Any) -> str:
  if isinstance(value, dict):
    special = value.get("$numberDouble")

    if special == "Infinity":
      return "math.huge"

    if special == "-Infinity":
      return "-math.huge"

    raise ValueError(f"unsupported vector number: {value}")

  if isinstance(value, bool) or not isinstance(value, (int, float)):
    raise ValueError(f"unsupported vector number: {value}")

  return repr(value)


def load_cases() -> list[dict[str, Any]]:
  cases = []

  for path in sorted(CORPUS.glob("*.json")):
    document = json.loads(path.read_text(encoding="utf-8"))

    for case in document["tests"]:
      cases.append({
        **case,
        "path": path.relative_to(ROOT).as_posix(),
        "test_key": document["test_key"],
      })

  return cases


def lua_program(cases: list[dict[str, Any]]) -> str:
  rows = []

  for case in cases:
    values = case.get("vector")
    vector = (
      "nil"
      if values is None
      else "{" + ",".join(lua_number(value) for value in values) + "}"
    )
    rows.append("{%s,%s,%s,%s,%s,%s,%s}" % (
      lua_string(case["description"]),
      "true" if case["valid"] else "false",
      vector,
      str(int(case["dtype_hex"], 16)),
      str(case.get("padding", 0)),
      lua_string(case.get("canonical_bson", "")),
      lua_string(case["test_key"]),
    ))

  return f'''package.path = "src/?.lua;src/?/init.lua;" .. package.path
local bson = require("mongodb.bson")

local function from_hex(hex)
  return (hex:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function to_hex(bytes)
  return (bytes:gsub(".", function(byte)
    return string.format("%02X", byte:byte())
  end))
end

local function same_number(expected, actual)
  if expected == math.huge or expected == -math.huge then
    return expected == actual
  end

  return math.abs(expected - actual) <= 0.00001
end

local cases = {{
{','.join(rows)}
}}

for index, case in ipairs(cases) do
  local description = case[1]
  local valid = case[2]
  local values = case[3]
  local dtype = case[4]
  local padding = case[5]
  local canonical = case[6]
  local key = case[7]

  if valid then
    local binary = bson.vector(values, dtype, padding)
    local document = bson.document({{ {{ key, binary }} }})

    assert(to_hex(assert(bson.encode(document))) == canonical, description .. ": encode")
    local decoded = assert(bson.decode(from_hex(canonical)))
    local vector = decoded:get(key):as_vector()

    assert(vector.dtype == dtype, description .. ": dtype")
    assert(vector.padding == padding, description .. ": padding")
    local observed = vector.data:values()

    assert(#observed == #values, description .. ": length")

    for value_index = 1, #values do
      assert(
        same_number(values[value_index], observed[value_index]),
        description .. ": value " .. value_index
      )
    end
  else
    if values ~= nil then
      assert(not pcall(bson.vector, values, dtype, padding), description .. ": encoded")
    end

    if canonical ~= "" then
      local decoded = assert(bson.decode(from_hex(canonical)))
      assert(not pcall(function()
        decoded:get(key):as_vector()
      end), description .. ": decoded")
    end
  end
end

assert(not pcall(
  bson.vector,
  {{ 255 }},
  bson.VECTOR_DTYPE.PACKED_BIT,
  7
), "non-zero ignored bits encoded")
assert(not pcall(function()
  bson.binary("\\16\\7\\255", bson.BINARY_SUBTYPE.VECTOR):as_vector()
end), "non-zero ignored bits decoded")

print(#cases .. " BSON vector subtype cases passed")
'''


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  args = parser.parse_args()
  cases = load_cases()
  process = subprocess.run(
    [args.lua, "-"],
    cwd=ROOT,
    env=os.environ.copy(),
    input=lua_program(cases),
    text=True,
    capture_output=True,
  )

  if process.returncode != 0:
    print(process.stdout + process.stderr, file=sys.stderr)
    return process.returncode

  print(process.stdout, end="")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
