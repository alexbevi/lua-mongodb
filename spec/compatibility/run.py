#!/usr/bin/env python3
"""Run one pinned MongoDB compatibility row and write environment facts."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterator
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]

if str(ROOT) not in sys.path:
  sys.path.insert(0, str(ROOT))

from spec.compatibility import matrix
from spec import sharded_environment as sharded_cluster


PROBE = ROOT / "spec" / "compatibility" / "probe.lua"
SHARDED_PROBE = ROOT / "spec" / "compatibility" / "sharded_probe.lua"
UNIFIED_EXECUTOR = ROOT / "spec" / "unified" / "execute.lua"
TLS_FIXTURES = ROOT / "spec" / "fixtures" / "tls"
REPLICA_SET = "lua-mongodb-compat"
USERNAME = "compat"
PASSWORD = "compat-password"
TLS_CLUSTER_PASSWORD = "test-client-password"
PROFILE_OPTIONS = {
  "plain": {"auth": False, "test_commands": False, "tls": False},
  "test-commands": {"auth": False, "test_commands": True, "tls": False},
  "auth": {"auth": True, "test_commands": False, "tls": False},
  "tls": {"auth": False, "test_commands": False, "tls": True},
  "auth-tls": {"auth": True, "test_commands": True, "tls": True},
}


class CompatibilityError(RuntimeError):
  """Raised when a required live compatibility check fails."""


class EnvironmentUnavailable(CompatibilityError):
  """Raised when the requested external test environment cannot be created."""


def free_port() -> int:
  with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    return int(listener.getsockname()[1])


def run_checked(
  command: list[str],
  *,
  environment: dict[str, str] | None = None,
  timeout: int = 60,
) -> subprocess.CompletedProcess[str]:
  completed = subprocess.run(
    command,
    cwd=ROOT,
    env=environment,
    capture_output=True,
    text=True,
    timeout=timeout,
  )

  if completed.returncode != 0:
    detail = (completed.stderr or completed.stdout).strip()
    raise CompatibilityError(
      f"command failed ({completed.returncode}): {command[0]}: {detail[-2000:]}"
    )

  return completed


def docker_ready(docker: str) -> None:
  if shutil.which(docker) is None:
    raise EnvironmentUnavailable(f"Docker executable is unavailable: {docker}")

  completed = subprocess.run(
    [docker, "info"],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    timeout=15,
  )

  if completed.returncode != 0:
    raise EnvironmentUnavailable("Docker daemon is unavailable")


def prepare_tls(directory: Path) -> Path:
  ca_file = directory / "ca.pem"
  combined = directory / "server-combined.pem"
  cluster = directory / "cluster-combined.pem"

  shutil.copyfile(TLS_FIXTURES / "ca.pem", ca_file)
  shutil.copyfile(TLS_FIXTURES / "client.pem", cluster)
  combined.write_bytes(
    (TLS_FIXTURES / "server.pem").read_bytes()
    + (TLS_FIXTURES / "server-key.pem").read_bytes()
  )
  os.chmod(directory, 0o755)
  os.chmod(ca_file, 0o444)
  os.chmod(combined, 0o444)
  os.chmod(cluster, 0o444)
  return ca_file


def mongosh_command(
  docker: str,
  container: str,
  port: int,
  profile: dict[str, bool],
  expression: str,
  *,
  authenticated: bool = False,
) -> list[str]:
  command = [
    docker, "exec", container, "mongosh",
    f"mongodb://127.0.0.1:{port}/admin",
    "--quiet",
  ]

  if profile["tls"]:
    command.extend(["--tls", "--tlsCAFile", "/compat/ca.pem"])

  if authenticated:
    command.extend([
      "--username", USERNAME,
      "--password", PASSWORD,
      "--authenticationDatabase", "admin",
    ])

  command.extend(["--eval", expression])
  return command


def wait_for_server(
  docker: str,
  container: str,
  port: int,
  profile: dict[str, bool],
) -> None:
  deadline = time.monotonic() + 40

  while time.monotonic() < deadline:
    status = subprocess.run(
      mongosh_command(docker, container, port, profile, "db.runCommand({ping:1})"),
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )

    if status.returncode == 0:
      return

    time.sleep(0.25)

  logs = subprocess.run(
    [docker, "logs", container],
    capture_output=True,
    text=True,
  )
  detail = (logs.stderr or logs.stdout).strip()
  raise CompatibilityError(f"MongoDB did not become ready: {detail[-2000:]}")


def configure_server(
  docker: str,
  container: str,
  port: int,
  topology: str,
  profile: dict[str, bool],
) -> None:
  wait_for_server(docker, container, port, profile)

  if topology == "replicaset":
    initiate = (
      f'rs.initiate({{_id:"{REPLICA_SET}",members:['
      f'{{_id:0,host:"127.0.0.1:{port}"}}]}})'
    )
    run_checked(mongosh_command(docker, container, port, profile, initiate))
    deadline = time.monotonic() + 30

    while time.monotonic() < deadline:
      primary = subprocess.run(
        mongosh_command(
          docker,
          container,
          port,
          profile,
          "quit(db.hello().isWritablePrimary ? 0 : 1)",
        ),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
      )

      if primary.returncode == 0:
        break

      time.sleep(0.25)
    else:
      raise CompatibilityError("single-member replica set did not elect a primary")

  if profile["auth"]:
    run_checked(mongosh_command(
      docker,
      container,
      port,
      profile,
      (
        'db.createUser({user:"compat",pwd:"compat-password",'
        'roles:[{role:"root",db:"admin"}]})'
      ),
    ))


def mongod_arguments(
  port: int,
  topology: str,
  profile: dict[str, bool],
) -> list[str]:
  arguments = [
    "mongod",
    "--bind_ip_all",
    "--nounixsocket",
    "--port", str(port),
    "--quiet",
  ]

  if topology == "replicaset":
    arguments.extend(["--replSet", REPLICA_SET])

  if profile["test_commands"]:
    arguments.extend(["--setParameter", "enableTestCommands=1"])

  if profile["auth"]:
    arguments.append("--auth")

    if topology == "replicaset":
      arguments.extend(["--keyFile", "/tmp/lua-mongodb-keyfile"])

  if profile["tls"]:
    arguments.extend([
      "--tlsMode", "requireTLS",
      "--tlsCertificateKeyFile", "/compat/server-combined.pem",
      "--tlsCAFile", "/compat/ca.pem",
      "--tlsAllowConnectionsWithoutCertificates",
    ])

  return arguments


@contextmanager
def live_server(
  server: dict[str, Any],
  profile_name: str,
  docker: str,
) -> Iterator[tuple[str, dict[str, Any]]]:
  profile = PROFILE_OPTIONS[profile_name]

  if server["topology"] == "sharded":
    with tempfile.TemporaryDirectory(prefix="lua-mongodb-compat-") as temporary:
      directory = Path(temporary)
      ca_file = prepare_tls(directory)

      try:
        with sharded_cluster.docker_cluster(
          docker=docker,
          image=server["image"],
          test_commands=profile["test_commands"],
          username=USERNAME if profile["auth"] else None,
          password=PASSWORD if profile["auth"] else None,
          tls_ca_file=ca_file if profile["tls"] else None,
          tls_certificate_key_file=(
            directory / "server-combined.pem" if profile["tls"] else None
          ),
          tls_cluster_file=(
            directory / "cluster-combined.pem" if profile["tls"] else None
          ),
          tls_cluster_password=(
            TLS_CLUSTER_PASSWORD if profile["tls"] else None
          ),
        ) as deployment:
          yield deployment["uri"], deployment["facts"]
      except sharded_cluster.ShardedEnvironmentError as exc:
        raise CompatibilityError(str(exc)) from exc

    return

  port = free_port()
  container = f"lua-mongodb-{server['series'].replace('.', '-')}-{server['topology']}-{profile_name}"

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-compat-") as temporary:
    directory = Path(temporary)
    ca_file = prepare_tls(directory)
    mongod = mongod_arguments(port, server["topology"], profile)

    shell = (
      "umask 077; "
      "printf '%s' LuaMongoDBCompatibilityKey1234567890 >/tmp/lua-mongodb-keyfile; "
      "exec \"$@\""
    )
    command = [
      docker, "run", "--detach", "--rm",
      "--name", container,
      "--network", "host",
      "--entrypoint", "/bin/sh",
      "--volume", f"{directory}:/compat:ro",
      server["image"],
      "-c", shell, "compat-entrypoint",
      *mongod,
    ]
    started = subprocess.run(command, capture_output=True, text=True, timeout=300)

    if started.returncode != 0:
      detail = (started.stderr or started.stdout).strip()
      raise CompatibilityError(f"could not start pinned MongoDB image: {detail}")

    try:
      configure_server(docker, container, port, server["topology"], profile)
      query = []

      if server["topology"] == "replicaset":
        query.append(f"replicaSet={REPLICA_SET}")

      if profile["tls"]:
        query.extend(["tls=true", "tlsCAFile=" + quote(str(ca_file), safe="")])

      query.extend(["serverSelectionTimeoutMS=5000", "heartbeatFrequencyMS=500"])
      credentials = f"{USERNAME}:{PASSWORD}@" if profile["auth"] else ""
      uri = f"mongodb://{credentials}127.0.0.1:{port}/admin?{'&'.join(query)}"
      facts_expression = (
        'const h=db.hello(); print(JSON.stringify({'
        'serverVersion:db.version(),'
        'isWritablePrimary:h.isWritablePrimary===true,'
        'setName:h.setName||null}))'
      )
      facts_result = run_checked(mongosh_command(
        docker,
        container,
        port,
        profile,
        facts_expression,
        authenticated=profile["auth"],
      ))
      facts = json.loads(facts_result.stdout.strip().splitlines()[-1])
      yield uri, facts
    finally:
      subprocess.run(
        [docker, "stop", "--time", "5", container],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
      )


def validate_server_facts(
  server: dict[str, Any],
  facts: dict[str, Any],
) -> None:
  if server["topology"] == "sharded":
    try:
      sharded_cluster.validate_facts(facts)
    except sharded_cluster.ShardedEnvironmentError as exc:
      raise CompatibilityError(str(exc)) from exc

    if facts["server_version"] != server["server_version"]:
      raise CompatibilityError(
        f"server reported {facts['server_version']}, "
        f"expected {server['server_version']}"
      )

    return

  expected_set = REPLICA_SET if server["topology"] == "replicaset" else None

  if facts["serverVersion"] != server["server_version"]:
    raise CompatibilityError(
      f"server reported {facts['serverVersion']}, expected {server['server_version']}"
    )

  if facts["setName"] != expected_set or not facts["isWritablePrimary"]:
    raise CompatibilityError("server environment facts do not match the matrix topology")


def run_profile(
  server: dict[str, Any],
  profile_name: str,
  docker: str,
  lua: str,
) -> dict[str, Any]:
  profile = PROFILE_OPTIONS[profile_name]

  with live_server(server, profile_name, docker) as (uri, facts):
    probe = SHARDED_PROBE if server["topology"] == "sharded" else PROBE
    run_checked([lua, str(probe), uri])
    identity = (
      server["test_commands_smoke_test"]
      if profile["test_commands"]
      else server["smoke_test"]
    )
    environment = os.environ.copy()
    prefixes = {
      "replicaset": "MONGODB_UNIFIED_REPLICA_SET",
      "sharded": "MONGODB_UNIFIED_SHARDED",
      "standalone": "MONGODB_UNIFIED",
    }
    prefix = prefixes[server["topology"]]

    environment[f"{prefix}_URI"] = uri
    environment[f"{prefix}_SERVER_VERSION"] = server["server_version"]

    if server["topology"] == "sharded":
      environment[f"{prefix}_FACTS"] = json.dumps(facts, sort_keys=True)

    environment["MONGODB_UNIFIED_TEST_COMMANDS"] = "1" if profile["test_commands"] else "0"
    run_checked([lua, str(UNIFIED_EXECUTOR), identity], environment=environment)
    validate_server_facts(server, facts)

    reported_version = (
      facts["server_version"]
      if server["topology"] == "sharded"
      else facts["serverVersion"]
    )
    reported_environment = {
      "authentication": profile["auth"],
      "image": server["image"],
      "server_version": reported_version,
      "test_commands": profile["test_commands"],
      "tls": profile["tls"],
      "topology": server["topology"],
    }

    if server["topology"] == "sharded":
      reported_environment.update({
        "config_server": facts["config_server"],
        "mongoses": facts["mongoses"],
        "shards": facts["shards"],
      })

    probe_gate = (
      "public-sharded-v0.4-smoke"
      if server["topology"] == "sharded"
      else "public-client-ping"
    )

    return {
      "environment": reported_environment,
      "gates": [probe_gate, f"unified:{identity}"],
      "profile": profile_name,
      "status": "passed",
    }


def summarize(server: dict[str, Any], profiles: list[dict[str, Any]]) -> dict[str, Any]:
  counts = {"environment_skipped": 0, "failed": 0, "passed": 0}

  for profile in profiles:
    counts[profile["status"]] += 1

  return {
    "entry": server["id"],
    "image": server["image"],
    "profiles": profiles,
    "report_version": 1,
    "server_version": server["server_version"],
    "summary": counts,
    "topology": server["topology"],
    "type": "compatibility",
  }


def write_report(report: dict[str, Any], destination: Path) -> None:
  destination.parent.mkdir(parents=True, exist_ok=True)
  destination.write_text(
    json.dumps(report, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
  )


def main(argv: list[str] | None = None) -> int:
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument("--entry", required=True)
  parser.add_argument("--matrix", type=Path, default=matrix.DEFAULT_MATRIX)
  parser.add_argument("--report", type=Path, required=True)
  parser.add_argument("--docker", default="docker")
  parser.add_argument("--lua", default="lua")
  parser.add_argument("--allow-environment-skip", action="store_true")
  args = parser.parse_args(argv)
  server = matrix.entry(matrix.load(args.matrix), args.entry)
  profiles = []

  try:
    docker_ready(args.docker)
  except EnvironmentUnavailable as exc:
    profiles = [
      {"profile": name, "status": "environment_skipped", "reason": str(exc)}
      for name in server["profiles"]
    ]
    write_report(summarize(server, profiles), args.report)
    print(f"compatibility: {server['id']}: environment unavailable: {exc}")
    return 0 if args.allow_environment_skip else 75

  for name in server["profiles"]:
    try:
      result = run_profile(server, name, args.docker, args.lua)
    except (CompatibilityError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
      profiles.append({"profile": name, "status": "failed", "reason": str(exc)})
      write_report(summarize(server, profiles), args.report)
      print(f"compatibility: {server['id']}/{name}: failed: {exc}")
      return 1

    profiles.append(result)
    print(f"compatibility: {server['id']}/{name}: passed")

  report = summarize(server, profiles)
  write_report(report, args.report)
  print(
    f"compatibility: {server['id']}: {report['summary']['passed']} passed, "
    "0 failed, 0 environment-skipped"
  )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
