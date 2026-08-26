import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
API = ROOT / "docs" / "API.md"
MODULE_CLASSIFICATION = ROOT / "spec" / "module-classification.json"
RUNTIME_CAPABILITIES = (
  "clock.now",
  "clock.sleep",
  "clock.wall_time",
  "cancellation.new",
  "task.spawn",
  "task.await",
  "task.cancel",
  "lock.new",
  "process.identity",
  "environment.get",
  "file.read",
  "http.request",
  "dns.resolve_srv",
  "dns.resolve_txt",
  "socket.connect",
  "tls.wrap",
  "entropy.bytes",
  "crypto.md5",
  "crypto.sha1",
  "crypto.sha256",
  "crypto.hmac_sha1",
  "crypto.hmac_sha256",
  "crypto.pbkdf2_sha1",
  "crypto.pbkdf2_sha256",
)


class ReadmeContentTests(unittest.TestCase):
  def test_load_balanced_support_is_current(self) -> None:
    readme = README.read_text(encoding="utf-8")

    self.assertIn("loadBalanced=true", readme)
    self.assertNotIn(
      "Load-balanced deployment execution remains outside the current scope",
      readme,
    )
    self.assertNotIn("The public surface currently includes", readme)

  def test_headings_use_sentence_case(self) -> None:
    readme = README.read_text(encoding="utf-8")

    for heading in (
      "# MongoDB Lua Driver",
      "## Building and Installing",
      "## Getting Started",
      "### URI Options",
      "### CRUD Operations",
      "### Change Streams",
      "### Bulk Operations",
      "### Generic Commands",
      "### Index Management",
      "#### Search Indexes",
    ):
      self.assertNotIn(heading, readme)

  def test_local_links_resolve(self) -> None:
    documents = (README, API)

    for document in documents:
      contents = document.read_text(encoding="utf-8")

      for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", contents):
        if "://" in target or target.startswith("#"):
          continue

        path = target.split("#", 1)[0]
        with self.subTest(document=document.name, target=target):
          self.assertTrue((document.parent / path).exists(), target)

  def test_api_stability_policy_is_linked_and_explicit(self) -> None:
    readme = README.read_text(encoding="utf-8")
    api = API.read_text(encoding="utf-8")

    self.assertIn("[API reference and stability policy](docs/API.md)", readme)

    for tier in (
      "Public",
      "Advanced extension",
      "Compatibility only",
      "Internal",
      "Test only",
    ):
      with self.subTest(tier=tier):
        self.assertIn(f"| {tier} |", api)

    self.assertIn("Patch releases preserve", api)
    self.assertIn("incompatible change", api)
    self.assertIn("minor release", api)
    self.assertIn("Internal and test-only modules carry no compatibility promise", api)

  def test_api_reference_names_every_supported_entry_point(self) -> None:
    api = API.read_text(encoding="utf-8")
    classification = json.loads(
      MODULE_CLASSIFICATION.read_text(encoding="utf-8")
    )

    for name, entry in classification["modules"].items():
      if entry["stability"] in ("public", "advanced-extension"):
        with self.subTest(module=name):
          self.assertIn(f"| `{name}` |", api)
      elif entry["stability"] == "compatibility-only":
        with self.subTest(module=name):
          self.assertIn(f"`{name}`", api)

    for name in classification["exports"]:
      with self.subTest(export=name):
        self.assertIn(f"`{name}`", api)

  def test_core_api_reference_has_exact_contracts(self) -> None:
    api = API.read_text(encoding="utf-8")

    for signature in (
      "mongodb.client(uri [, options]) -> client | nil, err",
      "mongodb.gridfs_bucket(database [, options]) -> bucket | nil, err",
      "mongodb.index_model(keys [, options]) -> index_model",
      "mongodb.run(callback, ...) -> ...",
      "mongodb.error.new(options) -> err",
      "mongodb.error.is(value [, category]) -> boolean",
      "mongodb.error.has_label(value, label) -> boolean",
      "mongodb.error.with_label(err, label) -> err",
      "mongodb.error.without_label(err, label) -> err",
      "err:has_label(label) -> boolean",
      "err:is_category(category) -> boolean",
      "err:is_timeout() -> boolean",
      "err:is_retryable() -> boolean",
      "mongodb.runtime.copas([options]) -> runtime",
      "mongodb.runtime.validate(runtime) -> runtime",
      "mongodb.runtime.required_capabilities() -> paths",
      "mongodb.runtime.deadline_after(runtime, duration) -> deadline",
      "mongodb.runtime.remaining(runtime, deadline) -> seconds | nil",
      "mongodb.runtime.check(runtime [, deadline [, cancellation]]) -> true | nil, err",
      "mongodb.runtime.cancelled_error([reason]) -> err",
      "mongodb.runtime.timeout_error() -> err",
      "mongodb.runtime.fake.new([options]) -> runtime",
      "mongodb.runtime.luasec.new(runtime [, options]) -> tls_provider",
      "mongodb.runtime.snappy.new(binding) -> compression_provider",
      "mongodb.runtime.snappy.load([loader]) -> compression_provider | nil",
      "mongodb.runtime.zlib.new(binding) -> compression_provider",
      "mongodb.runtime.zlib.load([loader]) -> compression_provider | nil",
      "mongodb.runtime.zstandard.new(binding) -> compression_provider",
      "mongodb.runtime.zstandard.load([loader]) -> compression_provider | nil",
    ):
      with self.subTest(signature=signature):
        self.assertIn(f"`{signature}`", api)

    for field in (
      "category",
      "message",
      "code",
      "code_name",
      "labels",
      "cause",
      "server",
      "topology",
      "timeout",
      "retryable",
      "details",
    ):
      with self.subTest(error_field=field):
        self.assertIn(f"| `{field}` |", api)

    for capability in RUNTIME_CAPABILITIES:
      with self.subTest(runtime_capability=capability):
        self.assertIn(f"`{capability}`", api)

    self.assertIn("owns the Copas loop", api)
    self.assertIn("caller-supplied runtime", api)
    self.assertIn("Operational failures return `nil, err`", api)
    self.assertIn("Programmer errors raise", api)


if __name__ == "__main__":
  unittest.main()
