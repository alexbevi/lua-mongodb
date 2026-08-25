"""Own an ephemeral replica-set-backed sharded MongoDB test environment."""

from __future__ import annotations

from contextlib import contextmanager, ExitStack
import json
from pathlib import Path
import re
import select
import shutil
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
from typing import Any, Iterator
from urllib.parse import quote


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


class _ProxyServer(socketserver.ThreadingTCPServer):
  allow_reuse_address = True
  daemon_threads = True


class _ProxyHandler(socketserver.BaseRequestHandler):
  def handle(self) -> None:
    server = self.server
    target_port = server.target_port
    source_host, source_port = self.request.getpeername()
    destination_host, destination_port = self.request.getsockname()
    header = b"\r\n\r\n\x00\r\nQUIT\n" + struct.pack(
      "!BBH4s4sHH",
      0x21,
      0x11,
      12,
      socket.inet_aton(source_host),
      socket.inet_aton(destination_host),
      source_port,
      destination_port,
    )

    with socket.create_connection(("127.0.0.1", target_port)) as upstream:
      upstream.sendall(header)
      peers = {
        self.request: upstream,
        upstream: self.request,
      }

      while True:
        readable, _, _ = select.select(tuple(peers), (), (), 1)

        for source in readable:
          data = source.recv(65536)

          if not data:
            return

          peers[source].sendall(data)


@contextmanager
def load_balancer_proxy(target_port: int) -> Iterator[int]:
  """Forward TCP with the PROXY v2 header required by loadBalancerPort."""
  server = _ProxyServer(("127.0.0.1", 0), _ProxyHandler)
  server.target_port = target_port
  thread = threading.Thread(target=server.serve_forever, daemon=True)
  thread.start()

  try:
    yield int(server.server_address[1])
  finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


def _docker_checked(
  command: list[str],
  *,
  timeout: int = 300,
) -> subprocess.CompletedProcess[str]:
  try:
    completed = subprocess.run(
      command,
      capture_output=True,
      text=True,
      timeout=timeout,
    )
  except (OSError, subprocess.TimeoutExpired) as exc:
    raise ShardedEnvironmentError(f"could not run Docker: {exc}") from exc

  if completed.returncode != 0:
    detail = (completed.stderr or completed.stdout).strip()
    raise ShardedEnvironmentError(
      f"Docker command failed ({completed.returncode}): {detail[-2000:]}"
    )

  return completed


def _docker_logs(docker: str, container: str) -> str:
  completed = subprocess.run(
    [docker, "logs", container],
    capture_output=True,
    text=True,
  )
  return (completed.stderr or completed.stdout).strip()[-2000:]


def _wait_for_docker_port(
  docker: str,
  container: str,
  port: int,
  label: str,
  deadline: float,
) -> None:
  while time.monotonic() < deadline:
    status = subprocess.run(
      [docker, "inspect", "--format", "{{.State.Running}}", container],
      capture_output=True,
      text=True,
    )

    if status.returncode != 0 or status.stdout.strip() != "true":
      raise ShardedEnvironmentError(
        f"ephemeral {label} exited: {_docker_logs(docker, container)}"
      )

    try:
      with socket.create_connection(("127.0.0.1", port), timeout=0.2):
        return
    except OSError:
      time.sleep(0.05)

  raise ShardedEnvironmentError(
    f"ephemeral {label} did not become ready within 60 seconds: "
    f"{_docker_logs(docker, container)}"
  )


def _run_docker_shell(
  docker: str,
  container: str,
  uri: str,
  expression: str,
  *,
  tls: bool,
  username: str | None = None,
  password: str | None = None,
) -> str:
  command = [docker, "exec", container, "mongosh", uri, "--quiet"]

  if tls:
    command.extend(["--tls", "--tlsCAFile", "/compat/ca.pem"])

  if username is not None and password is not None:
    command.extend([
      "--username", username,
      "--password", password,
      "--authenticationDatabase", "admin",
    ])

  command.extend(["--eval", expression])
  return _docker_checked(command, timeout=60).stdout.strip()


def _initiate_docker_replica_set(
  docker: str,
  container: str,
  uri: str,
  set_name: str,
  port: int,
  *,
  config_server: bool,
  deadline: float,
  tls: bool,
) -> None:
  config = (
    f'{{_id:"{set_name}",'
    + ("configsvr:true," if config_server else "")
    + f'members:[{{_id:0,host:"127.0.0.1:{port}"}}]}}'
  )
  _run_docker_shell(
    docker,
    container,
    uri,
    (
      f"const result=rs.initiate({config});"
      "if(!result.ok){throw new Error(JSON.stringify(result))}"
    ),
    tls=tls,
  )

  while time.monotonic() < deadline:
    try:
      _run_docker_shell(
        docker,
        container,
        uri,
        "quit(db.hello().isWritablePrimary ? 0 : 1)",
        tls=tls,
      )
      return
    except ShardedEnvironmentError:
      time.sleep(0.1)

  raise ShardedEnvironmentError(
    f"ephemeral replica set {set_name} did not elect a primary"
  )


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
def docker_cluster(
  *,
  docker: str,
  image: str,
  mongos_count: int = 1,
  test_commands: bool = True,
  username: str | None = None,
  password: str | None = None,
  tls_ca_file: Path | None = None,
  tls_certificate_key_file: Path | None = None,
  tls_cluster_file: Path | None = None,
  tls_cluster_password: str | None = None,
) -> Iterator[dict[str, Any]]:
  """Start an image-pinned sharded cluster for compatibility validation."""
  if type(mongos_count) is not int or mongos_count < 1 or mongos_count > 2:
    raise ShardedEnvironmentError("mongos_count must be 1 or 2")

  auth = username is not None or password is not None

  if auth and (not username or not password):
    raise ShardedEnvironmentError(
      "sharded authentication requires both username and password"
    )

  tls = any((
    tls_ca_file is not None,
    tls_certificate_key_file is not None,
    tls_cluster_file is not None,
    tls_cluster_password is not None,
  ))

  if tls and (
    tls_ca_file is None
    or tls_certificate_key_file is None
    or tls_cluster_file is None
    or not tls_cluster_password
  ):
    raise ShardedEnvironmentError(
      "sharded TLS requires CA, server, and cluster certificate-key files"
    )

  config_port, shard_port, *mongos_ports = _free_ports(2 + mongos_count)
  config_host = f"127.0.0.1:{config_port}"
  shard_host = f"127.0.0.1:{shard_port}"
  mongos_hosts = [f"127.0.0.1:{port}" for port in mongos_ports]
  config_server = f"{CONFIG_SET}/{config_host}"
  shard = f"{SHARD_SET}/{shard_host}"
  identifier = str(mongos_ports[0])

  with tempfile.TemporaryDirectory(prefix="lua-mongodb-compat-sharded-") as temp:
    root = Path(temp)
    containers: list[str] = []

    if tls:
      shutil.copyfile(tls_ca_file, root / "ca.pem")
      shutil.copyfile(
        tls_certificate_key_file,
        root / "server-combined.pem",
      )
      shutil.copyfile(tls_cluster_file, root / "cluster-combined.pem")
      (root / "ca.pem").chmod(0o444)
      (root / "server-combined.pem").chmod(0o444)
      (root / "cluster-combined.pem").chmod(0o444)

    if auth:
      key_file = root / "keyfile"
      key_file.write_text(
        "LuaMongoDBCompatibilityKey1234567890",
        encoding="utf-8",
      )
      key_file.chmod(0o400)

    root.chmod(0o755)
    common = [
      "--bind_ip", "127.0.0.1",
      "--nounixsocket",
      "--quiet",
    ]
    test_parameters = (
      ["--setParameter", "enableTestCommands=1"] if test_commands else []
    )
    security_arguments = []

    if auth:
      security_arguments.extend(["--keyFile", "/compat/keyfile"])

    if tls:
      security_arguments.extend([
        "--tlsMode", "requireTLS",
        "--tlsCertificateKeyFile", "/compat/server-combined.pem",
        "--tlsCAFile", "/compat/ca.pem",
        "--tlsClusterFile", "/compat/cluster-combined.pem",
        "--tlsClusterPassword", tls_cluster_password,
        "--tlsAllowConnectionsWithoutCertificates",
      ])

    def start_container(
      name: str,
      executable: str,
      arguments: list[str],
    ) -> None:
      _docker_checked([
        docker, "run", "--detach",
        "--name", name,
        "--network", "host",
        "--user", "0:0",
        "--entrypoint", executable,
        "--volume", f"{root}:/compat:ro",
        image,
        *arguments,
      ])
      containers.append(name)

    try:
      replica_sets = (
        (
          "config server",
          config_port,
          CONFIG_SET,
          "--configsvr",
          f"lua-mongodb-{identifier}-config",
        ),
        (
          "shard server",
          shard_port,
          SHARD_SET,
          "--shardsvr",
          f"lua-mongodb-{identifier}-shard",
        ),
      )

      for label, port, set_name, role, container in replica_sets:
        start_container(
          container,
          "mongod",
          [
            *common,
            "--dbpath", "/data/db",
            "--port", str(port),
            "--replSet", set_name,
            role,
            *test_parameters,
            *security_arguments,
          ],
        )
        deadline = time.monotonic() + 60
        _wait_for_docker_port(
          docker,
          container,
          port,
          label,
          deadline,
        )
        _initiate_docker_replica_set(
          docker,
          container,
          f"mongodb://127.0.0.1:{port}/admin",
          set_name,
          port,
          config_server=role == "--configsvr",
          deadline=deadline,
          tls=tls,
        )

      mongos_containers = []

      for index, mongos_port in enumerate(mongos_ports):
        container = f"lua-mongodb-{identifier}-mongos-{index}"
        start_container(
          container,
          "mongos",
          [
            "--bind_ip", "127.0.0.1",
            "--configdb", config_server,
            "--port", str(mongos_port),
            "--quiet",
            *test_parameters,
            *security_arguments,
          ],
        )
        mongos_containers.append(container)
        _wait_for_docker_port(
          docker,
          container,
          mongos_port,
          f"mongos {index + 1}",
          time.monotonic() + 60,
        )

      shell_container = mongos_containers[0]
      shell_uri = f"mongodb://{mongos_hosts[0]}/admin"
      _run_docker_shell(
        docker,
        shell_container,
        shell_uri,
        (
          "const result=db.adminCommand({"
          f'addShard:"{shard}",name:"{SHARD_ID}"'
          "});if(!result.ok){throw new Error(JSON.stringify(result))}"
        ),
        tls=tls,
      )

      if auth:
        _run_docker_shell(
          docker,
          shell_container,
          shell_uri,
          (
            "const result=db.runCommand({"
            f"createUser:{json.dumps(username)},"
            f"pwd:{json.dumps(password)},"
            'roles:[{role:"root",db:"admin"}]'
            "});if(!result.ok){throw new Error(JSON.stringify(result))}"
          ),
          tls=tls,
        )

      facts_output = _run_docker_shell(
        docker,
        shell_container,
        shell_uri,
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
        tls=tls,
        username=username,
        password=password,
      )

      try:
        facts = validate_facts(json.loads(facts_output.splitlines()[-1]))
      except (IndexError, json.JSONDecodeError) as exc:
        raise ShardedEnvironmentError(
          "mongos did not report valid environment facts"
        ) from exc

      if (
        facts["config_server"] != config_server
        or facts["mongoses"] != mongos_hosts
        or facts["shards"] != [{"host": shard, "id": SHARD_ID}]
      ):
        raise ShardedEnvironmentError(
          "mongos environment facts do not match owned containers"
        )

      credentials = ""

      if auth:
        credentials = (
          f"{quote(username, safe='')}:{quote(password, safe='')}@"
        )

      query = [
        "serverSelectionTimeoutMS=5000",
        "heartbeatFrequencyMS=500",
      ]

      if tls:
        query.extend([
          "tls=true",
          "tlsCAFile=" + quote(str(tls_ca_file), safe=""),
        ])

      uri = (
        f"mongodb://{credentials}{mongos_hosts[0]}/admin?"
        + "&".join(query)
      )
      multiple_mongos_uri = (
        f"mongodb://{credentials}{','.join(mongos_hosts)}/admin?"
        + "&".join(query)
      )
      yield {
        "facts": facts,
        "multiple_mongos_uri": multiple_mongos_uri,
        "test_commands": test_commands,
        "uri": uri,
      }
    finally:
      for container in reversed(containers):
        subprocess.run(
          [docker, "stop", "--time", "5", container],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
        )
        subprocess.run(
          [docker, "rm", "--force", container],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
        )


@contextmanager
def cluster(
  *,
  mongod: str | None = None,
  mongos: str | None = None,
  mongosh: str | None = None,
  mongos_count: int = 1,
  test_commands: bool = True,
  load_balanced: bool = False,
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
  ports = _free_ports(2 + mongos_count + (1 if load_balanced else 0))
  config_port = ports[0]
  shard_port = ports[1]
  mongos_ports = ports[2:2 + mongos_count]
  load_balancer_port = ports[-1] if load_balanced else None
  config_host = f"127.0.0.1:{config_port}"
  shard_host = f"127.0.0.1:{shard_port}"
  mongos_hosts = [f"127.0.0.1:{port}" for port in mongos_ports]
  config_server = f"{CONFIG_SET}/{config_host}"
  shard = f"{SHARD_SET}/{shard_host}"
  uri = f"mongodb://{mongos_hosts[0]}"
  multiple_mongos_uri = "mongodb://" + ",".join(mongos_hosts)

  with (
    tempfile.TemporaryDirectory(prefix="lua-mongodb-unified-sharded-") as temp,
    ExitStack() as adapters,
  ):
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
        load_balancer_arguments = []

        if index == 0 and load_balancer_port is not None:
          load_balancer_arguments = [
            "--setParameter", f"loadBalancerPort={load_balancer_port}",
          ]

        mongos_process = subprocess.Popen(
          [
            mongos,
            "--bind_ip", "127.0.0.1",
            "--configdb", config_server,
            "--logpath", str(mongos_log),
            "--port", str(mongos_port),
            "--quiet",
            *load_balancer_arguments,
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

        if index == 0 and load_balancer_port is not None:
          _wait_for_port(
            mongos_process,
            load_balancer_port,
            mongos_log,
            "load-balanced mongos",
            time.monotonic() + 60,
          )

      load_balancer_frontend = None

      if load_balancer_port is not None:
        load_balancer_frontend = adapters.enter_context(
          load_balancer_proxy(load_balancer_port)
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
        "load_balanced_uri": (
          f"mongodb://127.0.0.1:{load_balancer_frontend}/"
          "?loadBalanced=true&serverSelectionTimeoutMS=5000"
          "&heartbeatFrequencyMS=500"
          if load_balancer_frontend is not None else None
        ),
        "multiple_mongos_uri": multiple_mongos_uri,
        "process_ids": [process.pid for process in processes],
        "test_commands": test_commands,
        "uri": uri,
      }
    finally:
      _stop_processes(processes)
