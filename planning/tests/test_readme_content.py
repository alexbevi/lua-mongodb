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

  def test_bson_api_reference_has_exact_contracts(self) -> None:
    api = API.read_text(encoding="utf-8")

    for signature in (
      "bson.document(entries) -> document",
      "document:get(key) -> value | nil",
      "document:get_at(index) -> key, value | nil",
      "document:keys() -> keys",
      "document:entries() -> entries",
      "document:iter() -> iterator",
      "bson.array(values) -> array",
      "array:get(index) -> value | nil",
      "array:values() -> values",
      "array:iter() -> iterator",
      "bson.binary(data [, subtype]) -> binary",
      "binary:as_vector() -> vector",
      "bson.vector(values, dtype [, padding]) -> binary",
      "bson.int32(number) -> int32",
      "bson.int64(number) -> int64",
      "bson.double(number) -> double",
      "exact_number:to_number() -> number",
      "bson.decimal128(input) -> decimal128",
      "bson.decimal128_from_bid(bytes) -> decimal128",
      "decimal128:bid_hex() -> string",
      "bson.object_id(input) -> object_id",
      "bson.object_id_generator(runtime) -> generator | nil, err",
      "generator:new() -> object_id | nil, err",
      "bson.datetime(milliseconds) -> datetime",
      "bson.regex(pattern [, options]) -> regex",
      "bson.timestamp(time, increment) -> timestamp",
      "bson.code(source [, scope]) -> code",
      "bson.symbol(value) -> symbol",
      "bson.db_pointer(namespace, object_id) -> db_pointer",
      "bson.is_document(value) -> boolean",
      "bson.is_array(value) -> boolean",
      "bson.is_binary(value) -> boolean",
      "bson.is_null(value) -> boolean",
      "bson.is_exact(value [, kind]) -> boolean",
      "bson.is_tagged(value [, kind]) -> boolean",
      "bson.encode(document [, options]) -> bytes | nil, err",
      "bson.decode(bytes [, options]) -> document | nil, err",
      "bson.json.encode(value [, options]) -> text | nil, err",
      "bson.json.decode(text [, options]) -> value | nil, err",
      "bson.json.parse(text [, options]) -> value | nil, err",
    ):
      with self.subTest(signature=signature):
        self.assertIn(f"`{signature}`", api)

    for name in (
      "BINARY_SUBTYPE",
      "VECTOR_DTYPE",
      "null",
      "undefined",
      "min_key",
      "max_key",
    ):
      with self.subTest(bson_value=name):
        self.assertIn(f"`bson.{name}`", api)

    self.assertIn("preserves insertion order and duplicate keys", api)
    self.assertIn("last matching entry", api)
    self.assertIn("full signed 64-bit Lua integer range", api)
    self.assertIn("Canonical mode", api)
    self.assertIn("Relaxed mode", api)
    self.assertIn("Malformed BSON and JSON input returns a structured BSON error", api)
    self.assertIn("Invalid constructor arguments and codec options raise", api)

  def test_client_and_database_api_reference_has_exact_contracts(self) -> None:
    api = API.read_text(encoding="utf-8")

    self.assertIn("## Client and database handles", api)
    section = api.split("## Client and database handles", 1)[1]
    section = section.split("## BSON API", 1)[0]

    for signature in (
      "client:database([name [, options]]) -> database | nil, err",
      "client:start_session([options]) -> session | nil, err",
      "client:append_metadata(driver_info) -> boolean | nil, err",
      "client:close() -> boolean",
      "client:is_closed() -> boolean",
      "client:list_databases([options]) -> cursor | nil, err",
      "client:list_database_names([options]) -> names | nil, err",
      "client:drop_database(name_or_database [, options]) -> true | nil, err",
      "client:bulk_write(models [, options]) -> result | nil, err",
      "client:watch([pipeline [, options]]) -> change_stream | nil, err",
      "database:collection(name [, options]) -> collection | nil, err",
      "database:gridfs_bucket([options]) -> bucket | nil, err",
      "database:create_collection(name [, options]) -> collection | nil, err",
      "database:modify_collection(name [, options]) -> document | nil, err",
      "database:drop_collection(name_or_collection [, options]) -> true | nil, err",
      "database:list_collections([options]) -> cursor | nil, err",
      "database:list_collection_names([options]) -> names | nil, err",
      "database:run_command(command [, options]) -> document | nil, err",
      "database:run_cursor_command(command [, options]) -> cursor | nil, err",
      "database:aggregate(pipeline [, options]) -> cursor | nil, err",
      "database:watch([pipeline [, options]]) -> change_stream | nil, err",
    ):
      with self.subTest(signature=signature):
        self.assertIn(f"`{signature}`", section)

    for option in (
      "app_name",
      "auth_mechanism",
      "auth_mechanism_properties",
      "auth_source",
      "cancellation",
      "command_listeners",
      "compressors",
      "connect_timeout_ms",
      "deadline",
      "direct_connection",
      "driver_info",
      "heartbeat_frequency_ms",
      "heartbeat_listeners",
      "local_threshold_ms",
      "load_balanced",
      "max_connecting",
      "max_idle_time_ms",
      "max_pool_size",
      "min_pool_size",
      "on_listener_error",
      "pool_listeners",
      "read_concern",
      "read_preference",
      "replica_set",
      "retry_reads",
      "retry_writes",
      "runtime",
      "sdam_listeners",
      "server_api",
      "server_monitoring_mode",
      "server_selection_timeout_ms",
      "server_selection_try_once",
      "socket_timeout_ms",
      "srv_max_hosts",
      "srv_service_name",
      "timeout_ms",
      "tls",
      "tls_allow_invalid_certificates",
      "tls_allow_invalid_hostnames",
      "tls_ca_file",
      "tls_certificate_key_file",
      "tls_certificate_key_file_password",
      "tls_disable_certificate_revocation_check",
      "tls_disable_ocsp_endpoint_check",
      "tls_insecure",
      "wait_queue_timeout_ms",
      "write_concern",
      "zlib_compression_level",
    ):
      with self.subTest(client_option=option):
        self.assertIn(f"| `{option}` |", section)

    for contract in (
      "Programmatic client options use `snake_case`",
      "take precedence over URI options",
      "Database and collection handles borrow the client lifetime",
      "Closing a client closes",
      "A repeated close returns false",
      "one absolute operation deadline",
      "Generic commands do not append inherited read or write concerns",
      "NamespaceNotFound",
    ):
      with self.subTest(contract=contract):
        self.assertIn(contract, section)

  def test_collection_and_administration_api_reference_has_exact_contracts(
    self,
  ) -> None:
    api = API.read_text(encoding="utf-8")

    self.assertIn("## Collection and administration APIs", api)
    section = api.split("## Collection and administration APIs", 1)[1]
    section = section.split("## BSON API", 1)[0]

    for signature in (
      "collection:insert_one(document [, options]) -> result | nil, err",
      "collection:insert_many(documents [, options]) -> result | nil, err",
      "collection:bulk_write(models [, options]) -> result | nil, err",
      "collection:find([filter [, options]]) -> cursor | nil, err",
      "collection:find_one([filter [, options]]) -> document | nil, err",
      "collection:update_one(filter, update [, options]) -> result | nil, err",
      "collection:update_many(filter, update [, options]) -> result | nil, err",
      "collection:replace_one(filter, replacement [, options]) -> result | nil, err",
      "collection:delete_one(filter [, options]) -> result | nil, err",
      "collection:delete_many(filter [, options]) -> result | nil, err",
      "collection:aggregate(pipeline [, options]) -> cursor | nil, err",
      "collection:watch([pipeline [, options]]) -> change_stream | nil, err",
      "collection:count(filter [, options]) -> integer | nil, err",
      "collection:count_documents(filter [, options]) -> integer | nil, err",
      "collection:estimated_document_count([options]) -> integer | nil, err",
      "collection:distinct(key [, filter [, options]]) -> array | nil, err",
      "collection:map_reduce(map, reduce, out [, options]) -> value | nil, err",
      "collection:find_one_and_delete(filter [, options]) -> document | nil, err",
      "collection:find_one_and_replace(filter, replacement [, options]) -> document | nil, err",
      "collection:find_one_and_update(filter, update [, options]) -> document | nil, err",
      "collection:drop([options]) -> true | nil, err",
      "collection:rename(new_name [, options]) -> document | nil, err",
      "collection:create_index(keys_or_model [, options]) -> name | nil, err",
      "collection:create_indexes(models [, options]) -> names | nil, err",
      "collection:drop_index(name_or_model [, options]) -> true | nil, err",
      "collection:drop_indexes([options]) -> true | nil, err",
      "collection:list_indexes([options]) -> cursor | nil, err",
      "collection:create_search_index(model [, options]) -> name | nil, err",
      "collection:create_search_indexes(models [, options]) -> names | nil, err",
      "collection:update_search_index(name, definition [, options]) -> true | nil, err",
      "collection:drop_search_index(name [, options]) -> true | nil, err",
      "collection:list_search_indexes([name [, options]]) -> cursor | nil, err",
    ):
      with self.subTest(signature=signature):
        self.assertIn(f"`{signature}`", section)

    for field in (
      "acknowledged",
      "inserted_id",
      "inserted_ids",
      "inserted_count",
      "matched_count",
      "modified_count",
      "deleted_count",
      "upserted_count",
      "upserted_id",
      "upserted_ids",
    ):
      with self.subTest(result_field=field):
        self.assertIn(f"| `{field}` |", section)

    for contract in (
      "Collection operations inherit `read_concern`, `read_preference`, `write_concern`, and `timeout_ms`",
      "one authoritative timeout, cancellation, session, and error contract",
      "Unacknowledged results expose only `acknowledged = false`",
      "returns one Lua nil with no error when no document matches",
      "`update_many` does not accept `sort`",
      "`raw_data` is an internal conformance option",
      "Server code 26 (`NamespaceNotFound`) is treated as success",
    ):
      with self.subTest(contract=contract):
        self.assertIn(contract, section)

  def test_cursor_and_change_stream_api_reference_has_exact_lifecycle(
    self,
  ) -> None:
    api = API.read_text(encoding="utf-8")

    self.assertIn("## Cursor and change-stream APIs", api)
    section = api.split("## Cursor and change-stream APIs", 1)[1]
    section = section.split("## BSON API", 1)[0]

    for signature in (
      "cursor:next() -> document | nil, err",
      "cursor:iter() -> iterator",
      "cursor:is_closed() -> boolean",
      "cursor:close([options]) -> boolean | nil, err",
      "change_stream:next() -> document | nil, err",
      "change_stream:try_next() -> document | nil, err",
      "change_stream:iter() -> iterator",
      "change_stream:is_closed() -> boolean",
      "change_stream:resume_token() -> document | nil",
      "change_stream:close([options]) -> boolean | nil, err",
    ):
      with self.subTest(signature=signature):
        self.assertIn(f"`{signature}`", section)

    for contract in (
      "Ordinary cursors skip empty live batches",
      "Tailable cursors return one Lua nil with no error after one empty live batch",
      "Call `is_closed()` to distinguish",
      "`iter()` cannot expose an operational error to a generic Lua `for` loop",
      "`close()` returns false when the cursor was already closed",
      "Closing a client closes every registered cursor and change stream",
      "Every returned change event must have a non-nil `_id`",
      "`try_next()` performs at most one cursor advance when no resume is required",
      "one iteration timeout budget covers the read and any resume work",
      "A CSOT timeout leaves the stream open and schedules recreation for the next iteration",
      "`start_after` remains the resume position until the first change event",
      "After the first event, resumptions use `resume_after`",
      "post-batch resume token",
      "A second failure after an immediate recreation is returned without another resume",
      "A stream owns its cursor but not its client or explicit session",
    ):
      with self.subTest(contract=contract):
        self.assertIn(contract, section)


if __name__ == "__main__":
  unittest.main()
