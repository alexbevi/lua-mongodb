#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import sys


RUNTIME_IMPORT_PREFIXES = (
  "copas",
  "cqueues",
  "crypto",
  "ffi",
  "http",
  "luv",
  "openssl",
  "posix",
  "resty.openssl",
  "socket",
  "ssl",
)
RUNTIME_GLOBALS = ("io", "os", "package")


@dataclass(frozen=True)
class Token:
  kind: str
  value: str
  line: int


def long_bracket(source: str, position: int) -> tuple[int, int] | None:
  if position >= len(source) or source[position] != "[":
    return None

  cursor = position + 1

  while cursor < len(source) and source[cursor] == "=":
    cursor += 1

  if cursor >= len(source) or source[cursor] != "[":
    return None

  return cursor - position - 1, cursor + 1


def lua_tokens(source: str) -> list[Token]:
  tokens: list[Token] = []
  position = 0
  line = 1

  while position < len(source):
    character = source[position]

    if character.isspace():
      if character == "\n":
        line += 1
      position += 1
      continue

    if source.startswith("--", position):
      bracket = long_bracket(source, position + 2)

      if bracket is None:
        newline = source.find("\n", position + 2)

        if newline < 0:
          break

        position = newline
        continue

      equals, content_start = bracket
      closing = "]" + "=" * equals + "]"
      content_end = source.find(closing, content_start)

      if content_end < 0:
        break

      line += source.count("\n", position, content_end + len(closing))
      position = content_end + len(closing)
      continue

    if character in ("'", '"'):
      quote = character
      start_line = line
      cursor = position + 1
      value: list[str] = []

      while cursor < len(source):
        current = source[cursor]

        if current == "\\" and cursor + 1 < len(source):
          value.append(source[cursor + 1])
          cursor += 2
          continue

        if current == quote:
          cursor += 1
          break

        if current == "\n":
          line += 1

        value.append(current)
        cursor += 1

      tokens.append(Token("string", "".join(value), start_line))
      position = cursor
      continue

    bracket = long_bracket(source, position)

    if bracket is not None:
      equals, content_start = bracket
      closing = "]" + "=" * equals + "]"
      content_end = source.find(closing, content_start)

      if content_end < 0:
        content_end = len(source)
        closing = ""

      value = source[content_start:content_end]
      tokens.append(Token("string", value, line))
      line += value.count("\n")
      position = content_end + len(closing)
      continue

    if character.isalpha() or character == "_":
      cursor = position + 1

      while cursor < len(source):
        current = source[cursor]

        if not (current.isalnum() or current == "_"):
          break

        cursor += 1

      tokens.append(Token("identifier", source[position:cursor], line))
      position = cursor
      continue

    tokens.append(Token("symbol", character, line))
    position += 1

  return tokens


def literal_requires(tokens: list[Token]) -> list[tuple[str, int]]:
  imports: list[tuple[str, int]] = []

  for index, token in enumerate(tokens):
    if token.kind != "identifier" or token.value != "require":
      continue

    if index > 0 and tokens[index - 1].value in (".", ":"):
      continue

    cursor = index + 1

    if cursor < len(tokens) and tokens[cursor].value == "(":
      cursor += 1

    if cursor < len(tokens) and tokens[cursor].kind == "string":
      imports.append((tokens[cursor].value, token.line))

  return imports


def runtime_global_accesses(tokens: list[Token]) -> list[tuple[str, int]]:
  accesses: list[tuple[str, int]] = []

  for index in range(len(tokens) - 2):
    owner, separator, member = tokens[index:index + 3]

    if owner.kind == "identifier" and owner.value in RUNTIME_GLOBALS \
        and separator.value == "." and member.kind == "identifier":
      accesses.append((owner.value + "." + member.value, owner.line))

  return accesses


def module_name(root: Path, path: Path) -> str:
  parts = list(path.relative_to(root).with_suffix("").parts)

  if parts[-1] == "init":
    parts.pop()

  return "mongodb" + ("." + ".".join(parts) if parts else "")


def runtime_owned_import(name: str) -> bool:
  return any(name == prefix or name.startswith(prefix + ".")
             for prefix in RUNTIME_IMPORT_PREFIXES)


def runtime_module(name: str) -> bool:
  return name == "mongodb.runtime" or name.startswith("mongodb.runtime.")


def dependency_cycles(graph: dict[str, set[str]]) -> list[str]:
  state: dict[str, int] = {}
  stack: list[str] = []
  stack_positions: dict[str, int] = {}
  cycles: list[str] = []
  seen_cycles: set[tuple[str, ...]] = set()

  def visit(module: str) -> None:
    state[module] = 1
    stack_positions[module] = len(stack)
    stack.append(module)

    for dependency in sorted(graph[module]):
      if state.get(dependency, 0) == 0:
        visit(dependency)
      elif state.get(dependency) == 1:
        cycle = tuple(stack[stack_positions[dependency]:] + [dependency])

        if cycle not in seen_cycles:
          seen_cycles.add(cycle)
          cycles.append("dependency cycle: " + " -> ".join(cycle))

    stack.pop()
    stack_positions.pop(module)
    state[module] = 2

  for module in sorted(graph):
    if state.get(module, 0) == 0:
      visit(module)

  return cycles


def check_source(root: Path) -> list[str]:
  root = root.resolve()
  paths = sorted(root.rglob("*.lua"))
  modules = {module_name(root, path): path for path in paths}
  graph = {name: set() for name in modules}
  boundary_issues: list[str] = []

  for name in sorted(modules):
    path = modules[name]
    relative = path.relative_to(root).as_posix()
    tokens = lua_tokens(path.read_text(encoding="utf-8"))
    imports = literal_requires(tokens)

    for dependency, line in imports:
      if dependency in modules:
        graph[name].add(dependency)

      if not runtime_module(name) \
          and runtime_owned_import(dependency):
        boundary_issues.append(
          f"{relative}:{line}: {name} imports runtime-owned module "
          f"'{dependency}'"
        )

    if not runtime_module(name):
      for access, line in runtime_global_accesses(tokens):
        boundary_issues.append(
          f"{relative}:{line}: {name} accesses runtime-owned global '{access}'"
        )

  return dependency_cycles(graph) + boundary_issues


def build_parser() -> argparse.ArgumentParser:
  parser = argparse.ArgumentParser(
    description="Validate the production Lua dependency graph and runtime boundaries."
  )
  parser.add_argument(
    "root",
    nargs="?",
    type=Path,
    default=Path("src/mongodb"),
    help="production Lua module root (default: src/mongodb)",
  )
  return parser


def main(arguments: list[str] | None = None) -> int:
  options = build_parser().parse_args(arguments)

  if not options.root.is_dir():
    print(f"architecture root is not a directory: {options.root}", file=sys.stderr)
    return 2

  issues = check_source(options.root)

  if issues:
    for issue in issues:
      print(issue, file=sys.stderr)

    return 1

  print(f"Lua architecture boundaries are valid under {options.root}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
