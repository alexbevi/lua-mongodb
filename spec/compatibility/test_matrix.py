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

    self.assertEqual(6, len(document["servers"]))
    self.assertEqual(
      30,
      sum(len(server["profiles"]) for server in document["servers"]),
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
      self.assertFalse(kwargs["test_commands"])
      yield {
        "facts": facts,
        "test_commands": False,
        "uri": "mongodb://127.0.0.1:27017",
      }

    with mock.patch.object(run.sharded_cluster, "cluster", deployment):
      with run.live_server(
        {"series": "8.0", "topology": "sharded"},
        "plain",
        "unused-docker",
      ) as actual:
        self.assertEqual(("mongodb://127.0.0.1:27017", facts), actual)

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

    with (
      mock.patch.object(run, "live_server", live),
      mock.patch.object(run, "run_checked"),
    ):
      result = run.run_profile(server, "plain", "docker", "lua")

    self.assertEqual(facts["config_server"], result["environment"]["config_server"])
    self.assertEqual(facts["mongoses"], result["environment"]["mongoses"])
    self.assertEqual(facts["shards"], result["environment"]["shards"])


if __name__ == "__main__":
  unittest.main()
