"""Own an ephemeral replica-set-backed sharded MongoDB test environment."""

from __future__ import annotations

from contextlib import contextmanager
import json
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
from typing import Any, Iterator


CONFIG_SET = "lua-mongodb-config"
SHARD_SET = "lua-mongodb-shard"
SHARD_ID = "shard0"
FACT_KEYS = {
  "config_server", "mongoses", "server_version", "shards", "topology",
}


class ShardedEnvironmentError(RuntimeError):
  """Raised when a sharded test deployment cannot be created or verified."""


def _free_ports(count: int) -> list[int]:
  ports: list[int] = []

  while len(ports) < count:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
      listener.bind(("127.0.0.1", 0))
      port = int(listener.getsockname()[1])

    if port not in ports:
      ports.append(port)

  return ports


def _server_version(executable: str) -> str:
  try:
    completed = subprocess.run(
      [executable, "--version"],
      check=True,
      capture_output=True,
      text=True,
      timeout=30,
    )
  except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
    raise ShardedEnvironmentError(f"could not inspect mongod: {exc}") from exc

  match = re.search(r"db version v(\d+\.\d+\.\d+)", completed.stdout)

  if not match:
    raise ShardedEnvironmentError(
      "mongod --version did not report a semantic version"
    )

  return match.group(1)


def _tail(path: Path) -> str:
  if not path.exists():
    return ""

  return path.read_text(encoding="utf-8", errors="replace")[-2000:].strip()


def _stop_processes(processes: list[subprocess.Popen[bytes]]) -> None:
  for process in reversed(processes):
    if process.poll() is None:
      process.terminate()

  for process in reversed(processes):
    if process.poll() is not None:
      continue

    try:
      process.wait(timeout=10)
    except subprocess.TimeoutExpired:
      process.kill()
      process.wait(timeout=5)


def _wait_for_port(
  process: subprocess.Popen[bytes],
  port: int,
  log: Path,
  label: str,
  deadline: float,
) -> None:
  while time.monotonic() < deadline:
    if process.poll() is not None:
      raise ShardedEnvironmentError(
        f"ephemeral {label} exited {process.returncode}: {_tail(log)}"
      )

    try:
      with socket.create_connection(("127.0.0.1", port), timeout=0.2):
        return
    except OSError:
      time.sleep(0.05)

  raise ShardedEnvironmentError(
    f"ephemeral {label} did not become ready within 60 seconds"
  )


def _run_shell(
  executable: str,
  uri: str,
  expression: str,
  *,
  timeout: int = 60,
) -> str:
  try:
    completed = subprocess.run(
      [executable, uri, "--quiet", "--eval", expression],
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except (OSError, subprocess.TimeoutExpired) as exc:
    raise ShardedEnvironmentError(f"could not run mongosh: {exc}") from exc

  if completed.returncode != 0:
    detail = (completed.stderr or completed.stdout).strip()
    raise ShardedEnvironmentError(f"mongosh failed: {detail[-2000:]}")

  return completed.stdout.strip()


def _initiate_replica_set(
  shell: str,
  uri: str,
  set_name: str,
  port: int,
  *,
  config_server: bool,
  deadline: float,
) -> None:
  config = (
    f'{{_id:"{set_name}",'
    + ("configsvr:true," if config_server else "")
    + f'members:[{{_id:0,host:"127.0.0.1:{port}"}}]}}'
  )
  _run_shell(
    shell,
    uri,
    (
      f"const result=rs.initiate({config});"
      "if(!result.ok){throw new Error(JSON.stringify(result))}"
    ),
  )

  while time.monotonic() < deadline:
    completed = subprocess.run(
      [
        shell,
        uri,
        "--quiet",
        "--eval",
        "quit(db.hello().isWritablePrimary ? 0 : 1)",
      ],
      stdout=subprocess.DEVNULL,
      stderr=subprocess.DEVNULL,
    )

    if completed.returncode == 0:
      return

    time.sleep(0.1)

  raise ShardedEnvironmentError(
    f"ephemeral replica set {set_name} did not elect a primary"
  )


def validate_facts(facts: Any) -> dict[str, Any]:
  """Validate and return exact sharded environment facts."""
  if not isinstance(facts, dict) or set(facts) != FACT_KEYS:
    raise ShardedEnvironmentError("sharded environment facts have invalid fields")

  if facts["topology"] != "sharded-replicaset":
    raise ShardedEnvironmentError(
      "sharded environment topology must be sharded-replicaset"
    )

  if not isinstance(facts["server_version"], str) or not re.fullmatch(
    r"\d+\.\d+\.\d+", facts["server_version"]
  ):
    raise ShardedEnvironmentError("sharded server_version must be semantic")

  if not isinstance(facts["config_server"], str) or "/" not in facts[
    "config_server"
  ]:
    raise ShardedEnvironmentError("sharded config_server must name a replica set")

  mongoses = facts["mongoses"]

  if (
    not isinstance(mongoses, list)
    or not mongoses
    or not all(isinstance(host, str) and ":" in host for host in mongoses)
  ):
    raise ShardedEnvironmentError("sharded mongoses must be a non-empty host list")

  shards = facts["shards"]

  if not isinstance(shards, list) or not shards:
    raise ShardedEnvironmentError("sharded shards must be a non-empty array")

  for shard in shards:
    if (
      not isinstance(shard, dict)
      or set(shard) != {"host", "id"}
      or not isinstance(shard["id"], str)
      or not isinstance(shard["host"], str)
      or "/" not in shard["host"]
    ):
      raise ShardedEnvironmentError("sharded shard facts are malformed")

  return facts


@contextmanager
def cluster(
  *,
  mongod: str | None = None,
  mongos: str | None = None,
  mongosh: str | None = None,
  mongos_count: int = 1,
  test_commands: bool = True,
) -> Iterator[dict[str, Any]]:
  """Start, verify, and always tear down one minimal sharded cluster."""
  if type(mongos_count) is not int or mongos_count < 1 or mongos_count > 2:
    raise ShardedEnvironmentError("mongos_count must be 1 or 2")

  mongod = mongod or shutil.which("mongod")
  mongos = mongos or shutil.which("mongos")
  mongosh = mongosh or shutil.which("mongosh")

  if not mongod or not mongos or not mongosh:
    raise ShardedEnvironmentError(
      "sharded cases require mongod, mongos, and mongosh"
    )

  version = _server_version(mongod)
  config_port, shard_port, *mongos_ports = _free_ports(2 + mongos_count)
  config_host = f"127.0.0.1:{config_port}"
  shard_host = f"127.0.0.1:{shard_port}"
  mongos_hosts = [f"127.0.0.1:{port}" for port in mongos_ports]
  config_server = f"{CONFIG_SET}/{config_host}"
  shard = f"{SHARD_SET}/{shard_host}"
  uri = f"mongodb://{mongos_hosts[0]}"
  multiple_mongos_uri = "mongodb://" + ",".join(mongos_hosts)

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-unified-sharded-") as temp:
    root = Path(temp)
    processes: list[subprocess.Popen[bytes]] = []
    common = [
      "--bind_ip", "127.0.0.1",
      "--nounixsocket",
      "--quiet",
    ]
    test_parameters = (
      ["--setParameter", "enableTestCommands=1"] if test_commands else []
    )

    try:
      for label, port, set_name, role in (
        ("config server", config_port, CONFIG_SET, "--configsvr"),
        ("shard server", shard_port, SHARD_SET, "--shardsvr"),
      ):
        database = root / label.replace(" ", "-")
        database.mkdir()
        log = root / f"{label.replace(' ', '-')}.log"
        process = subprocess.Popen(
          [
            mongod,
            *common,
            "--dbpath", str(database),
            "--logpath", str(log),
            "--port", str(port),
            "--replSet", set_name,
            role,
            *test_parameters,
          ],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
        )
        processes.append(process)
        deadline = time.monotonic() + 60
        _wait_for_port(process, port, log, label, deadline)
        _initiate_replica_set(
          mongosh,
          f"mongodb://127.0.0.1:{port}",
          set_name,
          port,
          config_server=role == "--configsvr",
          deadline=deadline,
        )

      for index, mongos_port in enumerate(mongos_ports):
        mongos_log = root / f"mongos-{index}.log"
        mongos_process = subprocess.Popen(
          [
            mongos,
            "--bind_ip", "127.0.0.1",
            "--configdb", config_server,
            "--logpath", str(mongos_log),
            "--port", str(mongos_port),
            "--quiet",
            *test_parameters,
          ],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
        )
        processes.append(mongos_process)
        _wait_for_port(
          mongos_process,
          mongos_port,
          mongos_log,
          f"mongos {index + 1}",
          time.monotonic() + 60,
        )
      _run_shell(
        mongosh,
        uri,
        (
          "const result=db.adminCommand({"
          f'addShard:"{shard}",name:"{SHARD_ID}"'
          "});if(!result.ok){throw new Error(JSON.stringify(result))}"
        ),
      )
      facts_output = _run_shell(
        mongosh,
        uri,
        (
          "const hello=db.hello();"
          "const options=db.adminCommand({getCmdLineOpts:1});"
          "const listed=db.adminCommand({listShards:1});"
          "print(JSON.stringify({"
          "config_server:options.parsed.sharding.configDB,"
          f"mongoses:{json.dumps(mongos_hosts)},"
          "server_version:db.version(),"
          "shards:listed.shards.map(s=>({id:s._id,host:s.host})),"
          "topology:hello.msg===\"isdbgrid\"?"
          "\"sharded-replicaset\":\"unknown\"}))"
        ),
      )

      try:
        facts = validate_facts(json.loads(facts_output.splitlines()[-1]))
      except (IndexError, json.JSONDecodeError) as exc:
        raise ShardedEnvironmentError(
          "mongos did not report valid environment facts"
        ) from exc

      if (
        facts["server_version"] != version
        or facts["config_server"] != config_server
        or facts["mongoses"] != mongos_hosts
        or facts["shards"] != [{"host": shard, "id": SHARD_ID}]
      ):
        raise ShardedEnvironmentError(
          "mongos environment facts do not match owned processes"
        )

      yield {
        "facts": facts,
        "multiple_mongos_uri": multiple_mongos_uri,
        "process_ids": [process.pid for process in processes],
        "test_commands": test_commands,
        "uri": uri,
      }
    finally:
      _stop_processes(processes)
