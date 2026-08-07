#!/usr/bin/env python3
"""Validate the pinned live MongoDB compatibility matrix."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MATRIX = ROOT / "spec" / "compatibility" / "matrix.json"
REQUIRED_SERIES = {"7.0", "8.0", "8.2"}
REQUIRED_TOPOLOGIES = {"standalone", "replicaset"}
REQUIRED_PROFILES = {"plain", "test-commands", "auth", "tls", "auth-tls"}
IMAGE = re.compile(
  r"^mongodb/mongodb-community-server:"
  r"(?P<version>\d+\.\d+\.\d+)-ubuntu2204@sha256:[0-9a-f]{64}$"
)


class MatrixError(ValueError):
  """Raised when compatibility coverage is incomplete or not reproducible."""


def load(path: Path = DEFAULT_MATRIX) -> dict[str, Any]:
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except (OSError, json.JSONDecodeError) as exc:
    raise MatrixError(f"cannot read compatibility matrix {path}: {exc}") from exc


def validate(
  document: dict[str, Any], required_series: set[str] = REQUIRED_SERIES
) -> dict[str, Any]:
  if document.get("schema_version") != 1:
    raise MatrixError("compatibility matrix schema_version must be 1")

  servers = document.get("servers")

  if not isinstance(servers, list) or not servers:
    raise MatrixError("compatibility matrix servers must be a non-empty array")

  expected_pairs = {
    (series, topology)
    for series in required_series
    for topology in REQUIRED_TOPOLOGIES
  }
  actual_pairs = {
    (server.get("series"), server.get("topology"))
    for server in servers
  }

  for series, topology in sorted(expected_pairs - actual_pairs):
    raise MatrixError(f"missing compatibility topology: {series}/{topology}")

  unexpected_pairs = actual_pairs - expected_pairs

  if unexpected_pairs:
    series, topology = sorted(unexpected_pairs)[0]
    raise MatrixError(f"unexpected compatibility topology: {series}/{topology}")

  if len(actual_pairs) != len(servers):
    raise MatrixError("compatibility matrix contains a duplicate series/topology row")

  ids = set()

  for server in servers:
    expected_keys = {
      "id", "image", "profiles", "series", "server_version", "smoke_test",
      "test_commands_smoke_test", "topology",
    }

    if set(server) != expected_keys:
      raise MatrixError(f"compatibility row has invalid fields: {server.get('id')}")

    identifier = server["id"]

    if not isinstance(identifier, str) or not identifier:
      raise MatrixError("compatibility row id must be a non-empty string")

    if identifier in ids:
      raise MatrixError(f"duplicate compatibility row id: {identifier}")

    ids.add(identifier)
    expected_id = f"mongodb-{server['series']}-{server['topology']}"

    if identifier != expected_id:
      raise MatrixError(f"compatibility row id must be {expected_id}")

    image_match = IMAGE.fullmatch(server["image"])

    if not image_match:
      raise MatrixError(f"compatibility image is not immutably pinned: {identifier}")

    if image_match.group("version") != server["server_version"]:
      raise MatrixError(f"compatibility image version does not match: {identifier}")

    if not server["server_version"].startswith(server["series"] + "."):
      raise MatrixError(f"compatibility server series does not match: {identifier}")

    profiles = server["profiles"]

    if not isinstance(profiles, list) or set(profiles) != REQUIRED_PROFILES:
      raise MatrixError(
        f"compatibility row must cover plain, test-commands, auth, TLS, "
        f"and auth+TLS profiles: {identifier}"
      )

    if len(profiles) != len(REQUIRED_PROFILES):
      raise MatrixError(f"compatibility row has duplicate profiles: {identifier}")

    for field in ("smoke_test", "test_commands_smoke_test"):
      value = server[field]

      if not isinstance(value, str) or "::test[" not in value:
        raise MatrixError(f"compatibility row has invalid {field}: {identifier}")

  return document


def entry(document: dict[str, Any], identifier: str) -> dict[str, Any]:
  validate(document)

  for server in document["servers"]:
    if server["id"] == identifier:
      return server

  raise MatrixError(f"unknown compatibility row: {identifier}")


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--matrix", type=Path, default=DEFAULT_MATRIX)
  args = parser.parse_args(argv)

  try:
    document = validate(load(args.matrix))
  except MatrixError as exc:
    print(f"compatibility matrix: {exc}")
    return 1

  print(
    f"compatibility matrix: {len(document['servers'])} rows, "
    f"{len(document['servers']) * len(REQUIRED_PROFILES)} profiles, "
    f"series={','.join(sorted(REQUIRED_SERIES))}"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
