"""Contract tests for the live MongoDB compatibility matrix."""

from contextlib import contextmanager
import unittest
from copy import deepcopy
from unittest import mock

from spec.compatibility import matrix
from spec.compatibility import run


class CompatibilityMatrixTests(unittest.TestCase):
  def test_rejects_a_matrix_that_omits_an_advertised_topology(self):
    document = {
      "schema_version": 1,
      "servers": [
        {
          "id": "mongodb-7.0-standalone",
          "image": "mongodb/mongodb-community-server:7.0.0-ubuntu2204",
          "series": "7.0",
          "topology": "standalone",
          "profiles": ["plain", "test-commands"],
        },
      ],
    }

    with self.assertRaisesRegex(
      matrix.MatrixError,
      "missing compatibility topology: 7.0/replicaset",
    ):
      matrix.validate(document, required_series={"7.0"})

  def test_checked_in_matrix_covers_every_profile_with_pinned_images(self):
    document = matrix.validate(matrix.load())

    self.assertEqual(9, len(document["servers"]))
    self.assertEqual(
      45,
      sum(len(server["profiles"]) for server in document["servers"]),
    )
    self.assertEqual(
      {"replicaset", "sharded", "standalone"},
      {server["topology"] for server in document["servers"]},
    )
    sharded = [
      server for server in document["servers"]
      if server["topology"] == "sharded"
    ]
    self.assertEqual(3, len(sharded))
    self.assertEqual(
      {"run-command/tests/unified/runCursorCommand.json::test[1]"},
      {server["smoke_test"] for server in sharded},
    )
    self.assertEqual(
      {"transactions/tests/unified/mongos-unpin.json::test[1]"},
      {server["test_commands_smoke_test"] for server in sharded},
    )

  def test_rejects_a_mutable_image_tag(self):
    document = deepcopy(matrix.load())
    document["servers"][0]["image"] = "mongodb/mongodb-community-server:8.2"

    with self.assertRaisesRegex(matrix.MatrixError, "immutably pinned"):
      matrix.validate(document)

  def test_report_distinguishes_failures_from_environment_skips(self):
    server = matrix.entry(matrix.load(), "mongodb-8.2-standalone")
    report = run.summarize(server, [
      {"profile": "plain", "status": "passed"},
      {"profile": "tls", "status": "failed", "reason": "probe failed"},
      {
        "profile": "auth",
        "status": "environment_skipped",
        "reason": "Docker unavailable",
      },
    ])

    self.assertEqual(
      {"environment_skipped": 1, "failed": 1, "passed": 1},
      report["summary"],
    )

  def test_tls_profile_uses_one_way_server_authentication(self):
    arguments = run.mongod_arguments(
      27017,
      "standalone",
      run.PROFILE_OPTIONS["tls"],
    )

    self.assertIn("--tlsMode", arguments)
    self.assertIn("--tlsAllowConnectionsWithoutCertificates", arguments)

  def test_sharded_environment_facts_are_exact(self):
    server = {
      "server_version": "8.0.16",
      "topology": "sharded",
    }
    facts = {
      "config_server": "lua-mongodb-config/127.0.0.1:27019",
      "mongoses": ["127.0.0.1:27017"],
      "server_version": "8.0.16",
      "shards": [{
        "host": "lua-mongodb-shard/127.0.0.1:27018",
        "id": "shard0",
      }],
      "topology": "sharded-replicaset",
    }

    run.validate_server_facts(server, facts)

    invalid = deepcopy(facts)
    invalid["topology"] = "replicaset"

    with self.assertRaisesRegex(
      run.CompatibilityError,
      "sharded-replicaset",
    ):
      run.validate_server_facts(server, invalid)

  def test_sharded_live_server_uses_the_shared_owned_environment(self):
    facts = {
      "config_server": "lua-mongodb-config/127.0.0.1:27019",
      "mongoses": ["127.0.0.1:27017"],
      "server_version": "8.0.16",
      "shards": [{
        "host": "lua-mongodb-shard/127.0.0.1:27018",
        "id": "shard0",
      }],
      "topology": "sharded-replicaset",
    }

    @contextmanager
    def deployment(**kwargs):
      self.assertEqual("docker", kwargs["docker"])
      self.assertEqual("pinned-image", kwargs["image"])
      self.assertFalse(kwargs["test_commands"])
      self.assertIsNone(kwargs["username"])
      self.assertIsNone(kwargs["password"])
      self.assertIsNone(kwargs["tls_ca_file"])
      self.assertIsNone(kwargs["tls_certificate_key_file"])
      self.assertIsNone(kwargs["tls_cluster_file"])
      self.assertIsNone(kwargs["tls_cluster_password"])
      yield {
        "facts": facts,
        "test_commands": False,
        "uri": "mongodb://127.0.0.1:27017",
      }

    with mock.patch.object(run.sharded_cluster, "docker_cluster", deployment):
      with run.live_server(
        {
          "image": "pinned-image",
          "series": "8.0",
          "topology": "sharded",
        },
        "plain",
        "docker",
      ) as actual:
        self.assertEqual(("mongodb://127.0.0.1:27017", facts), actual)

  def test_sharded_security_profile_uses_owned_auth_and_tls_inputs(self):
    facts = {
      "config_server": "lua-mongodb-config/127.0.0.1:27019",
      "mongoses": ["127.0.0.1:27017"],
      "server_version": "8.0.16",
      "shards": [{
        "host": "lua-mongodb-shard/127.0.0.1:27018",
        "id": "shard0",
      }],
      "topology": "sharded-replicaset",
    }

    @contextmanager
    def deployment(**kwargs):
      self.assertTrue(kwargs["test_commands"])
      self.assertEqual(run.USERNAME, kwargs["username"])
      self.assertEqual(run.PASSWORD, kwargs["password"])
      self.assertTrue(kwargs["tls_ca_file"].is_file())
      self.assertTrue(kwargs["tls_certificate_key_file"].is_file())
      self.assertTrue(kwargs["tls_cluster_file"].is_file())
      self.assertEqual(
        run.TLS_CLUSTER_PASSWORD,
        kwargs["tls_cluster_password"],
      )
      yield {
        "facts": facts,
        "test_commands": True,
        "uri": "mongodb://compat@127.0.0.1:27017/admin?tls=true",
      }

    server = {
      "image": "pinned-image",
      "series": "8.0",
      "topology": "sharded",
    }

    with mock.patch.object(
      run.sharded_cluster,
      "docker_cluster",
      deployment,
    ):
      with run.live_server(server, "auth-tls", "docker") as actual:
        self.assertEqual(facts, actual[1])

  def test_sharded_profile_reports_exact_environment_facts(self):
    facts = {
      "config_server": "lua-mongodb-config/127.0.0.1:27019",
      "mongoses": ["127.0.0.1:27017"],
      "server_version": "8.0.16",
      "shards": [{
        "host": "lua-mongodb-shard/127.0.0.1:27018",
        "id": "shard0",
      }],
      "topology": "sharded-replicaset",
    }
    server = {
      "image": "pinned-image",
      "server_version": "8.0.16",
      "smoke_test": "suite/tests/unified/test.json::test[1]",
      "test_commands_smoke_test": "suite/tests/unified/test.json::test[2]",
      "topology": "sharded",
    }

    @contextmanager
    def live(*args, **kwargs):
      yield "mongodb://127.0.0.1:27017", facts

    checked = mock.Mock()

    with (
      mock.patch.object(run, "live_server", live),
      mock.patch.object(run, "run_checked", checked),
    ):
      result = run.run_profile(server, "plain", "docker", "lua")

    self.assertEqual(
      ["lua", str(run.SHARDED_PROBE), "mongodb://127.0.0.1:27017"],
      checked.call_args_list[0].args[0],
    )
    self.assertEqual(
      "public-sharded-v0.4-smoke",
      result["gates"][0],
    )
    self.assertEqual(facts["config_server"], result["environment"]["config_server"])
    self.assertEqual(facts["mongoses"], result["environment"]["mongoses"])
    self.assertEqual(facts["shards"], result["environment"]["shards"])


if __name__ == "__main__":
  unittest.main()
