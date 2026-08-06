# Lua MongoDB Driver

This repository is the planning and implementation workspace for a pure-Lua MongoDB driver. It is pre-alpha: the standalone client, `run_command`, core CRUD, collection bulk-write, administration, and multi-batch cursor APIs are implemented while production topology behavior is added incrementally.

The driver will implement BSON, the MongoDB wire protocol, topology and connection management, authentication, sessions, retry behavior, and a unified specification-test runner in Lua. It will not wrap `libmongoc`. Native Lua modules may be used only behind runtime adapters for TCP, TLS, and cryptography.

## Core API

```lua
local copas = require("copas")
local mongodb = require("mongodb")

copas.loop(function()
  local client, err = mongodb.client("mongodb://localhost:27017/app", {
    runtime = mongodb.runtime.copas(),
  })

  if not client then
    print(err.message)
    return
  end

  local reply, command_err = client:database():run_command("ping")

  if not reply then
    print(command_err.message)
  end

  local users = client:database():collection("users")
  local inserted = assert(users:insert_one(
    mongodb.bson.document({ { "name", "Ada" } })
  ))
  local document = assert(users:find_one(inserted.inserted_id))

  print(document:get("name"))

  assert(users:update_one(
    mongodb.bson.document({ { "_id", inserted.inserted_id } }),
    mongodb.bson.document({ { "$set", mongodb.bson.document({ { "active", true } }) } })
  ))

  client:close()
end)
```

The initial compatibility target is Lua 5.4 with 64-bit `lua_Integer`, Copas 4.11, LuaSocket, LuaSec, luaossl, and MongoDB server 7.0 through 8.2. Operational failures return `nil, structured_error`; programmer misuse may raise a Lua error.

The implemented `mongodb.bson` foundation provides explicit ordered documents and arrays; immutable values for every BSON wire type; exact Decimal128 and numeric wrappers; strict UTF-8 validation; configurable size/depth bounds; and ordered canonical/relaxed Extended JSON. ObjectId generation takes a runtime so time and entropy stay portable. Explicit containers prevent Lua table iteration order from changing command bytes, while exact wrappers preserve numeric wire types and bit patterns.

`mongodb.config.uri.parse` implements the non-SRV connection-string syntax boundary. It parses ordered seed lists, bracketed IPv6 literals, encoded Unix socket paths, credentials, authentication databases, and ordered query pairs without rendering credentials in structured errors. `mongodb.config.options.normalize` applies the same type, range, and combination rules to those URI pairs and to idiomatic Lua option tables, with programmatic values taking precedence. The resulting immutable configuration includes pool and timeout settings, TLS policy, retry flags, read/write concerns, read preference, and Stable API version 1 fields.

Unsupported or invalid URI options are ignored with returned warnings as required by the connection-string specification; unsupported programmatic keys and invalid programmatic values return structured configuration errors. Advanced post-v1 settings such as compression, SRV, proxy, and load-balanced options are intentionally not accepted by the v1 programmatic configuration boundary.

The internal `mongodb.command.executor` performs the mandatory OP_MSG connection handshake and exact command exchange on one transport connection. It sends bounded client metadata, negotiates legacy `ismaster` to modern `hello`, carries Stable API settings and `$db` without mutating the caller's ordered command, validates correlated replies, and returns server codes, code names, labels, and response documents through structured errors. Command monitoring publishes immutable events with normative authentication redaction.

`mongodb.auth.scram` authenticates a handshaken command executor with SCRAM-SHA-256 or SCRAM-SHA-1, including secure nonces, the minimum iteration check, server nonce/signature verification, derived-key caching, and the optional third empty exchange. SCRAM-SHA-256 passwords pass through a pure-Lua Unicode 3.2 SASLprep implementation. The default Copas runtime obtains entropy and MD5/SHA/HMAC/PBKDF2 operations through its luaossl adapter; secrets are excluded from authentication errors and monitoring events. The public client negotiates SCRAM-SHA-256 when the server advertises it and otherwise falls back to SCRAM-SHA-1.

The default `mongodb.runtime.copas` runtime wraps established sockets with LuaSec when TLS is requested. It verifies the certificate chain and server name by default, sends SNI for DNS names, supports custom CA bundles and encrypted combined client certificate/key files, and applies the connection's absolute deadline and cancellation token throughout the handshake. `tlsInsecure` disables both chain and hostname verification; the two granular allow-invalid settings disable only their documented checks. LuaSec does not provide OCSP endpoint or CRL revocation checking, so the corresponding disable options do not change adapter behavior.

`mongodb.client` parses and normalizes a non-SRV URI, opens one standalone connection through the supplied runtime, performs TLS and hello, authenticates URI credentials with SCRAM, and returns immutable client, database, and collection handles. Database and collection handles inherit read concern, read preference, and write concern unless explicitly overridden. `database:run_command` accepts a command name or ordered BSON document; operational failures return structured errors. Closing a client is idempotent, and later operations on any of its database handles return a predictable client error. This initial lifecycle intentionally accepts exactly one TCP seed and owns one connection; pooling, replica-set discovery, sessions, and the remaining collection API belong to subsequent roadmap slices.

`collection:insert_one` accepts an ordered BSON document, preserves an existing `_id`, or prepends a generated ObjectId without mutating the caller's value. Its immutable result reports acknowledgement and the inserted identifier. `collection:find_one` accepts an ordered filter or an `_id` value and supports the initial find option set, always sending `limit: 1` and `singleBatch: true` so the server closes the cursor. Both operations inherit collection concerns.

`collection:update_one`, `update_many`, `replace_one`, `delete_one`, and `delete_many` build the corresponding ordered write-command models and return immutable acknowledgement and count results. Updates require either a non-empty atomic-modifier document or a non-empty pipeline; replacements reject atomic-modifier documents. Options include collation, comments, hints, `let`, raw data, update array filters, single-update sort, bypass-document-validation, and upsert where applicable. Unacknowledged writes use OP_MSG `moreToCome` and reject option combinations that cannot be safely sent at the negotiated wire version. Command-level failures keep their server response, while write and write-concern failures retain codes, labels, response documents, and unparsed `errInfo` in structured errors.

`collection:insert_many` and `collection:bulk_write` use immutable write models created by `mongodb.bulk.insert_one`, `update_one`, `update_many`, `replace_one`, `delete_one`, and `delete_many`. Ordered requests preserve adjacent operation runs; unordered requests group compatible commands. Both paths split OP_MSG document sequences at the server's negotiated BSON, message, and write-batch limits. Results expose immutable counts and identifiers, and partial write failures report original 1-based request indices even after grouping or batching. Retries and sessions remain in later slices; client-level bulk write remains post-v1.

Client administration includes `list_databases`, `list_database_names`, and `drop_database`. Database handles provide `create_collection`, `list_collections`, `list_collection_names`, and `drop_collection`; collection handles also provide `drop`. Collection and index listings use the normal immutable cursor lifecycle, including getMore and client-close cleanup.

Indexes are described by immutable `mongodb.index_model(keys, options)` values and managed with `create_index`, `create_indexes`, `list_indexes`, `drop_index`, and `drop_indexes`. Missing names are generated from ordered key-direction pairs, such as `kind_1_created_at_-1`. Index creation enforces the MongoDB 4.4 minimum for `commit_quorum`; internal raw-data command fields are emitted only for MongoDB 8.2 wire versions. Returned collection and index specification documents are preserved as reported by the server, including the absence of the historical `ns` field on modern servers. Retries and sessions remain in later slices; search-index management remains outside this v1 administration surface.

`mongodb.sdam` provides the pure, immutable server/topology description layer. It parses hello responses, applies the normative topology transition table, rejects stale topology versions and connection generations, and computes replica-set membership, compatibility, and logical-session timeout without performing I/O. Live monitor scheduling and public multi-seed replica-set clients follow in SDAM-002; the current public client therefore retains its single-seed lifecycle restriction.

`mongodb.selection` evaluates those snapshots for reads and writes. It supports all five read-preference modes, ordered tag-set fallback, max-staleness validation and estimation, address deprioritization, custom selector composition, latency windows, RTT averaging, and operation-count-aware power-of-two choice. Empty selection errors retain a description of the final topology. This is still a pure boundary: SDAM-002 will connect it to background monitoring and topology-change waits, and CMAP-001 will supply live operation counts.

`collection:find` returns an immutable cursor over the initial `firstBatch`. `cursor:next()` fetches subsequent batches with `getMore` and returns `nil, structured_error` on operational failure; `cursor:iter()` is available when only successful document iteration is needed. Batch sizes are capped by the remaining limit, and equal limit/batch-size inputs use the specification's `limit + 1` initial batch rule. Exhausted zero-id cursors close locally. Call `cursor:close()` when stopping early; it sends `killCursors` if the server cursor is still live. `client:close()` closes every registered cursor before closing its connection, providing deterministic cleanup without attempting coroutine network I/O from a garbage-collection finalizer.

`collection:aggregate` accepts an ordered BSON pipeline array and returns the same cursor type as `find`, including batch size, getMore comments, `max_await_time_ms`, explicit close, and client-close cleanup. `$out` and `$merge` pipelines apply write concern, omit the initial batch size, and support unacknowledged OP_MSG execution. `count_documents` uses the normative `$match`/`$skip`/`$limit`/`$group` aggregation pipeline and returns zero for an empty result; its `$match` stage has the server's normal aggregation restrictions, so query-only operators such as `$where`, `$near`, and `$nearSphere` are not supported. `distinct` returns the server's immutable BSON values array.

`estimated_document_count` uses the metadata-based `count` server command. MongoDB 5.0.0–5.0.8 omitted that command from Stable API v1, so applications using `api_strict` should use MongoDB 5.0.9 or newer. `find_one_and_delete`, `find_one_and_replace`, and `find_one_and_update` return the selected document or `nil`; update and replacement validation stays distinct, and `return_document = "before"` or `"after"` selects the returned version.

## Bootstrap

After cloning this repository, initialize the pinned references:

```sh
git submodule update --init --recursive
python3 planning/update_plan.py check
python3 planning/update_plan.py next
```

The roadmap lives in [`planning/plan.json`](planning/plan.json). [`planning/current_state.json`](planning/current_state.json) is generated from it and the mutable progress ledger. Use the commands documented in [`planning/README.md`](planning/README.md); do not edit generated state directly.

Architecture decisions are maintained in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), while [`planning/reference_architecture.md`](planning/reference_architecture.md) maps PyMongo and the MongoDB specifications to the planned Lua components.

## Development

The project requires Lua 5.4 with 64-bit `lua_Integer`, LuaRocks, Copas 4.11, luaossl, Busted 2.3, and Luacheck 1.2. Install the rockspec's runtime and development dependencies, then run:

```sh
make test-unit
make test-integration
make test-unified
make lint
make check
```

Every target checks its prerequisites and explains how to select a missing tool through `LUA`, `LUAROCKS`, `BUSTED`, `LUACHECK`, or `PYTHON`. `make test-unit` includes every pinned BSON and Extended JSON corpus representation, all 98 non-SRV connection-string fixtures plus their option-warning semantics, and the deterministic unified runner core. `make test-unified` validates all 320 distinct JSON meta-fixtures against the pinned unified schema 1.28 with the pure-Lua validator; real fixture execution remains incremental. Integration coverage includes real Copas/LuaSocket loopback transport, verified and insecure LuaSec handshakes, the public standalone lifecycle, OP_MSG handshake, SCRAM-SHA-256 authentication, and authenticated ping execution without requiring an external server process.

The unified capability CLI verifies that every pinned integration fixture is runnable or explicitly deferred. It supports repeatable glob filters and versioned JSON reports:

```sh
python3 spec/unified/run.py
python3 spec/unified/run.py --include 'run-command/**' --report report.json
python3 spec/unified/update_capabilities.py --check
```

The checked-in manifest currently classifies all 483 discovered fixtures with owning roadmap activities and concrete reasons. A missing fixture, stale entry, unknown status, empty deferral reason, or runnable fixture without an executor fails the command.

## Scope

The `production-core-v1` milestone covers standalone and replica-set CRUD, TLS and SCRAM, SDAM and CMAP, monitoring, sessions, retries, transactions, and client-side operation timeout. Advanced features such as change streams, GridFS, SRV, compression, sharded and load-balanced deployments, extra authentication mechanisms, and client bulk write remain post-v1. Client-side field-level/queryable encryption and GSSAPI require separate designs.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
