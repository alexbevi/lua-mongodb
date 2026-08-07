"""Contract tests for the live MongoDB compatibility matrix."""

import unittest
from copy import deepcopy

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


if __name__ == "__main__":
  unittest.main()
