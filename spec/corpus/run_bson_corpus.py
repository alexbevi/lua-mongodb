#!/usr/bin/env python3
"""Run the pinned BSON and Extended JSON corpus against the pure-Lua codecs."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / "planning" / "specifications" / "source" / "bson-corpus" / "tests"


def lua_string(value: str) -> str:
  encoded = json.dumps(value, ensure_ascii=True)

  if "\\u" in encoded:
    raise ValueError("corpus runner only embeds ASCII fixture values")

  return encoded


def load_cases() -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
  valid: list[dict[str, Any]] = []
  decode_errors: list[dict[str, Any]] = []
  parse_errors: list[dict[str, Any]] = []

  for path in sorted(CORPUS.glob("*.json")):
    suite = json.loads(path.read_text(encoding="utf-8"))

    for case in suite.get("valid", []):
      if "canonical_bson" not in case:
        raise ValueError(f"{path}: valid case lacks canonical_bson")

      valid.append({**case, "path": str(path.relative_to(ROOT))})

    for case in suite.get("decodeErrors", []):
      decode_errors.append({**case, "path": str(path.relative_to(ROOT))})

    for case in suite.get("parseErrors", []):
      parse_errors.append({
        **case,
        "path": str(path.relative_to(ROOT)),
        "suite": path.name,
      })

  return valid, decode_errors, parse_errors


def lua_program(
  valid: list[dict[str, Any]],
  decode_errors: list[dict[str, Any]],
  parse_errors: list[dict[str, Any]],
) -> str:
  valid_rows = []

  def encoded_json(case: dict[str, Any], field: str) -> str:
    representation = case.get(field)

    if representation is None:
      return "nil"

    return lua_string(base64.b64encode(representation.encode("utf-8")).decode("ascii"))

  for case in valid:
    degenerate = case.get("degenerate_bson")
    valid_rows.append("{%s,%s,%s,%s,%s,%s}" % (
      lua_string(case["canonical_bson"].lower()),
      "true" if not case.get("lossy", False) else "false",
      lua_string(degenerate.lower()) if degenerate else "nil",
      encoded_json(case, "canonical_extjson"),
      encoded_json(case, "degenerate_extjson"),
      encoded_json(case, "relaxed_extjson"),
    ))

  decode_rows = [lua_string(case["bson"].lower()) for case in decode_errors]
  parse_rows = []

  for case in parse_errors:
    encoded = base64.b64encode(case["string"].encode("utf-8")).decode("ascii")
    decimal = case["suite"].startswith("decimal128-")
    parse_rows.append("{%s,%s}" % (lua_string(encoded), "true" if decimal else "false"))

  return f'''package.path = "src/?.lua;src/?/init.lua;" .. package.path
local bson = require("mongodb.bson")
local base64 = require("mongodb.bson.base64")

local function from_hex(hex)
  return (hex:gsub("..", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local valid = {{
{",".join(valid_rows)}
}}
local decode_errors = {{
{",".join(decode_rows)}
}}
local parse_errors = {{
{",".join(parse_rows)}
}}

for index, vector in ipairs(valid) do
  local canonical = from_hex(vector[1])
  local document, err = bson.decode(canonical)

  assert(document, "valid index " .. index .. ": " .. tostring(err))

  if vector[2] then
    assert(assert(bson.encode(document)) == canonical, "valid index " .. index .. ": byte mismatch")
  end

  if vector[3] then
    local degenerate = assert(bson.decode(from_hex(vector[3])))
    assert(
      assert(bson.encode(degenerate)) == canonical,
      "valid index " .. index .. ": degenerate normalization mismatch"
    )
  end


  for form = 4, 6 do
    if vector[form] then
      local extended = assert(base64.decode(vector[form]))
      local converted, conversion_error = bson.json.decode(extended)

      assert(
        converted,
        "valid index " .. index .. " form " .. form .. ": " .. tostring(conversion_error)
      )

      if vector[2] and form ~= 6 then
        assert(
          assert(bson.encode(converted)) == canonical,
          "valid index " .. index .. " form " .. form .. ": BSON mismatch"
        )
      end
    end
  end

  for _, mode in ipairs({{ "canonical", "relaxed" }}) do
    local generated = assert(bson.json.encode(document, {{ mode = mode }}))
    local converted = assert(bson.json.decode(generated))

    if vector[2] and mode == "canonical" then
      assert(
        assert(bson.encode(converted)) == canonical,
        "valid index " .. index .. ": generated canonical mismatch"
      )
    end
  end
end

for index, encoded in ipairs(decode_errors) do
  assert(bson.decode(from_hex(encoded)) == nil, "decode-error index " .. index .. " accepted")
end

for index, vector in ipairs(parse_errors) do
  local input = assert(base64.decode(vector[1]))
  local accepted

  if vector[2] then
    accepted = pcall(bson.decimal128, input)
  else
    accepted = bson.json.decode(input) ~= nil
  end

  assert(not accepted, "parse-error index " .. index .. " accepted")
end

print(#valid .. " canonical BSON vectors passed")
print(#decode_errors .. " BSON decode-error vectors passed")
print(#parse_errors .. " BSON and Extended JSON parse-error vectors passed")
'''


def explain_failure(
  output: str,
  valid: list[dict[str, Any]],
  decode_errors: list[dict[str, Any]],
  parse_errors: list[dict[str, Any]],
) -> str:
  match = re.search(r"(valid|decode-error|parse-error) index (\d+)", output)

  if not match:
    return output

  cases = {
    "valid": valid,
    "decode-error": decode_errors,
    "parse-error": parse_errors,
  }[match.group(1)]
  case = cases[int(match.group(2)) - 1]
  return f"{output}\nfixture: {case['path']}: {case['description']}"


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--lua", default=os.environ.get("LUA", "lua"))
  arguments = parser.parse_args()
  valid, decode_errors, parse_errors = load_cases()
  process = subprocess.run(
    [arguments.lua, "-"],
    cwd=ROOT,
    env=os.environ.copy(),
    input=lua_program(valid, decode_errors, parse_errors),
    text=True,
    capture_output=True,
  )

  if process.returncode != 0:
    output = process.stdout + process.stderr
    print(explain_failure(output, valid, decode_errors, parse_errors), file=sys.stderr)
    return process.returncode

  print(process.stdout, end="")
  degenerate_count = sum("degenerate_bson" in case for case in valid)
  extended_json_count = sum(
    sum(field in case for field in ("canonical_extjson", "degenerate_extjson", "relaxed_extjson"))
    for case in valid
  )
  print(f"{degenerate_count} degenerate BSON vectors normalized")
  print(f"{extended_json_count} official Extended JSON representations passed")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
