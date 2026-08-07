# Lua MongoDB Driver

This repository is the planning and implementation workspace for a pure-Lua MongoDB driver. It is pre-alpha: standalone and monitored replica-set clients, `run_command`, core CRUD, collection bulk-write, administration, multi-batch cursors, causal sessions, retryable reads and writes, explicit and convenient replica-set transactions, and client-side operation timeout are implemented while production execution behavior is added incrementally.

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

The implemented `mongodb.bson` foundation provides explicit ordered documents and arrays; immutable values for every BSON wire type; exact Decimal128 and numeric wrappers; strict UTF-8 validation; configurable size/depth bounds; and ordered canonical/relaxed Extended JSON. `bson.vector(values, bson.VECTOR_DTYPE.INT8|FLOAT32|PACKED_BIT, padding)` creates validated binary subtype-9 values, and `binary:as_vector()` returns their immutable dtype, padding, and explicit BSON-array data. New encodings reject non-zero ignored PACKED_BIT bits. ObjectId generation takes a runtime so time and entropy stay portable. Explicit containers prevent Lua table iteration order from changing command bytes, while exact wrappers preserve numeric wire types and bit patterns.

`mongodb.config.uri.parse` implements the non-SRV connection-string syntax boundary. It parses ordered seed lists, bracketed IPv6 literals, encoded Unix socket paths, credentials, authentication databases, and ordered query pairs without rendering credentials in structured errors. `mongodb.config.options.normalize` applies the same type, range, and combination rules to those URI pairs and to idiomatic Lua option tables, with programmatic values taking precedence. The resulting immutable configuration includes pool and timeout settings, TLS policy, retry flags, read/write concerns, read preference, the single-threaded compatibility option, and Stable API version 1 fields. URI validation rejects `directConnection=true` with multiple seeds before any runtime adapter is selected.

Unsupported or invalid URI options are ignored with returned warnings as required by the connection-string specification; unsupported programmatic keys and invalid programmatic values return structured configuration errors. Repeated read-preference tag sets and equivalent `tls`/`ssl` aliases retain their normative no-warning behavior. The unit gate executes 114 applicable URI-option cases and all 38 read/write-concern configuration cases. Advanced post-v1 settings such as compression, SRV, proxy, and load-balanced options are intentionally not accepted by the v1 programmatic configuration boundary.

The internal `mongodb.command.executor` performs the mandatory OP_MSG connection handshake and exact command exchange on one transport connection. It sends bounded client metadata, negotiates legacy `ismaster` to modern `hello`, carries Stable API settings and `$db` without mutating the caller's ordered command, validates correlated replies, and returns server codes, code names, labels, and response documents through structured errors. Command monitoring publishes immutable events with normative authentication redaction.

`mongodb.auth.scram` authenticates a handshaken command executor with SCRAM-SHA-256 or SCRAM-SHA-1, including secure nonces, the minimum iteration check, server nonce/signature verification, derived-key caching, and the optional third empty exchange. SCRAM-SHA-256 passwords pass through a pure-Lua Unicode 3.2 SASLprep implementation. The default Copas runtime obtains entropy and MD5/SHA/HMAC/PBKDF2 operations through its luaossl adapter; secrets are excluded from authentication errors and monitoring events. The public client negotiates SCRAM-SHA-256 when the server advertises it and otherwise falls back to SCRAM-SHA-1.

The default `mongodb.runtime.copas` runtime wraps established sockets with LuaSec when TLS is requested. It verifies the certificate chain and server name by default, sends SNI for DNS names, supports custom CA bundles and encrypted combined client certificate/key files, and applies the connection's absolute deadline and cancellation token throughout the handshake. `tlsInsecure` disables both chain and hostname verification; the two granular allow-invalid settings disable only their documented checks. LuaSec does not provide OCSP endpoint or CRL revocation checking, so the corresponding disable options do not change adapter behavior.

`mongodb.client` parses and normalizes a non-SRV URI and returns immutable client, database, and collection handles. A standalone URI owns one runtime-backed connection. A `replicaSet` URI starts independent monitors for all seeds and discovered members, selects by operation and read preference, and checks authenticated application connections out of one pool per server. Database and collection handles inherit read concern, read preference, and write concern unless explicitly overridden. `database:run_command` accepts a command name or ordered BSON document; operational failures return structured errors. Closing a client is idempotent, cancels monitors, closes pools and monitor connections, and makes later handle operations return a predictable client error.

Set `timeout_ms` on a client, database, collection, session, or individual operation to enable client-side operation timeout. A positive value creates one monotonic deadline that covers server selection, pool checkout, connection/TLS/authentication setup, socket writes and aggregate reads, every bulk batch, retries, cursor continuation, and transaction work; nested work inherits the earlier deadline instead of resetting it. Zero means an infinite operation timeout and an omitted value leaves CSOT disabled. While CSOT is active it supersedes legacy socket, wait-queue, write-concern, and command timeouts, derives an integer `maxTimeMS` after blocking work and the minimum RTT budget, and reports local, socket, and server code-50 expiry as a distinct structured timeout retaining its cause. A manual `maxTimeMS` in `run_command` is replaced by the derived CSOT value; applications needing an independent server limit should leave `timeout_ms` unset.

Non-tailable cursors default to `timeout_mode = "cursor_lifetime"`: the initial operation deadline covers find/aggregate and all getMore commands, while already buffered documents remain readable after expiry. `timeout_mode = "iteration"` refreshes the timeout for each `next()` and suppresses derived `maxTimeMS` on both the initial command and getMore; it requires an effective `timeout_ms` and is rejected for `$out`/`$merge`. Cursor close refreshes the original budget for `killCursors`. Explicit sessions inherit the client timeout or accept `timeout_ms`; commit, abort, `with_transaction`, and session cleanup use that budget, and abort cleanup after a timed callback gets a fresh attempt budget.

`client:start_session()` creates an explicit causal session when the deployment advertises session support. Public CRUD, bulk, administration, and command options accept `session`; commands carry the session `lsid`, gossip the highest cluster time, and add `afterClusterTime` after the session observes an operation time. Operations without an explicit session use pooled implicit server sessions with causal consistency disabled. Multi-command bulk operations and cursor `getMore`/`killCursors` retain one implicit session until completion. Ended sessions are rejected, network-failed sessions are marked dirty and never pooled, expired sessions are discarded, and client close ends active sessions and sends `endSessions`.

Explicit replica-set transactions use `session:start_transaction(options)`, `session:commit_transaction()`, and `session:abort_transaction()`; `session:is_in_transaction()` exposes the active state. Transaction options accept BSON read and write concerns, a read preference, and `max_commit_time_ms`, while session `default_transaction_options` and client concerns supply inherited defaults. Commands use one `txnNumber`, add `startTransaction` only to the first command, always add `autocommit: false`, omit per-operation concerns, and merge causal `afterClusterTime`. Transaction reads reject non-primary read preference before I/O, `w=0` is rejected, empty transactions finish locally, commit and abort retry once where required, and commit errors receive the normative labels and majority write-concern promotion. `session:with_transaction(callback, options)` returns the callback value, aborts on callback failure, and retries transient transactions and indeterminate commits. With CSOT it uses the session or operation deadline without retry jitter; without CSOT it retains the 120-second monotonic budget and jittered backoff. Because the callback can run more than once, applications must make its external side effects idempotent. Mongos pinning and recovery tokens remain post-v1.

`collection:insert_one` accepts an ordered BSON document, preserves an existing `_id`, or prepends a generated ObjectId without mutating the caller's value. Its immutable result reports acknowledgement and the inserted identifier. `collection:find_one` accepts an ordered filter or an `_id` value and supports the initial find option set, always sending `limit: 1` and `singleBatch: true` so the server closes the cursor. Both operations inherit collection concerns.

`collection:update_one`, `update_many`, `replace_one`, `delete_one`, and `delete_many` build the corresponding ordered write-command models and return immutable acknowledgement and count results. Updates require either a non-empty atomic-modifier document or a non-empty pipeline; replacements reject atomic-modifier documents. Options include collation, comments, hints, `let`, raw data, update array filters, single-update sort, bypass-document-validation, and upsert where applicable. Unacknowledged writes use OP_MSG `moreToCome` and reject option combinations that cannot be safely sent at the negotiated wire version. Command-level failures keep their server response, while write and write-concern failures retain codes, labels, response documents, and unparsed `errInfo` in structured errors.

`collection:insert_many` and `collection:bulk_write` use immutable write models created by `mongodb.bulk.insert_one`, `update_one`, `update_many`, `replace_one`, `delete_one`, and `delete_many`. Ordered requests preserve adjacent operation runs; unordered requests group compatible commands. Both paths split OP_MSG document sequences at the server's negotiated BSON, message, and write-batch limits. Results expose immutable counts and identifiers, and partial write failures report original 1-based request indices even after grouping or batching. Retries remain in later slices; client-level bulk write remains post-v1.

Client administration includes `list_databases`, `list_database_names`, and `drop_database`. Database handles provide `create_collection`, `modify_collection`, `list_collections`, `list_collection_names`, and `drop_collection`; collection handles also provide `drop`. Collection creation accepts clustered-index and time-series documents plus time-series expiration, while views retain their source and pipeline options. `modify_collection` supports validator changes and index constraint transitions, inherits write concern, and preserves the server response in structured command errors. Collection and index listings use the normal immutable cursor lifecycle, including getMore and client-close cleanup.

Indexes are described by immutable `mongodb.index_model(keys, options)` values and managed with `create_index`, `create_indexes`, `list_indexes`, `drop_index`, and `drop_indexes`. Missing names are generated from ordered key-direction pairs, such as `kind_1_created_at_-1`. Every index operation inherits client/database/collection `timeout_ms` and accepts an operation override through the same absolute-deadline boundary. Index creation enforces the MongoDB 4.4 minimum for `commit_quorum`; internal raw-data command fields are emitted only for MongoDB 8.2 wire versions. Returned collection and index specification documents are preserved as reported by the server, including the absence of the historical `ns` field on modern servers. Retries remain in later slices; search-index management remains outside this v1 administration surface.

`mongodb.sdam` provides the pure, immutable server/topology description layer. It parses hello responses, applies the normative topology transition table, rejects stale topology versions and connection generations, and computes replica-set membership, compatibility, and logical-session timeout without performing I/O. `mongodb.topology` schedules dedicated polling or awaitable-hello monitors, publishes heartbeat and SDAM events, discovers and removes replica-set members, updates RTT, readies or clears each server pool, wakes selection waiters, and rejects late results after shutdown.

`mongodb.selection` evaluates those snapshots for reads and writes. It supports all five read-preference modes, ordered tag-set fallback, max-staleness validation and estimation, address deprioritization, custom selector composition, latency windows, RTT averaging, and operation-count-aware power-of-two choice. `mongodb.topology_executor` connects selection to topology-change waits and each pool's live operation count, checks commands out from the chosen server, and feeds application errors and pool generations back into SDAM. Empty selection errors retain a description of the final topology.

`mongodb.pool` provides a coroutine-safe per-server connection pool with FIFO checkout, `maxPoolSize`, `minPoolSize`, `maxConnecting`, wait-queue timeouts, idle pruning, generation-based clearing, interruption, deterministic close, and immutable CMAP events. Replica-set clients create one pool per discovered server and ready it only after a successful monitor check. Connection establishment is injected, so TCP, TLS, hello, and authentication stay behind their existing runtime and protocol adapters.

`collection:find` returns an immutable cursor over the initial `firstBatch`. `cursor:next()` fetches subsequent batches with `getMore` and returns `nil, structured_error` on operational failure; `cursor:iter()` is available when only successful document iteration is needed. Batch sizes are capped by the remaining limit, and equal limit/batch-size inputs use the specification's `limit + 1` initial batch rule. Exhausted zero-id cursors close locally. Call `cursor:close()` when stopping early; it sends `killCursors` if the server cursor is still live. `client:close()` closes every registered cursor before closing its connection, providing deterministic cleanup without attempting coroutine network I/O from a garbage-collection finalizer.

`collection:aggregate` accepts an ordered BSON pipeline array and returns the same cursor type as `find`, including batch size, getMore comments, `max_await_time_ms`, explicit close, and client-close cleanup. `$out` and `$merge` pipelines apply write concern, omit the initial batch size, support unacknowledged OP_MSG execution, and use an inherited non-primary read preference for replica-set selection and the `$readPreference` command argument on the supported MongoDB 7.0–8.2 matrix. `count_documents` uses the normative `$match`/`$skip`/`$limit`/`$group` aggregation pipeline and returns zero for an empty result; its `$match` stage has the server's normal aggregation restrictions, so query-only operators such as `$where`, `$near`, and `$nearSphere` are not supported. `distinct` returns the server's immutable BSON values array. The `find`, `aggregate`, `count_documents`, `estimated_document_count`, `distinct`, `list_collections`, and create/list/drop index helpers accept the internal boolean `raw_data` option; it is emitted as `rawData` on MongoDB 8.2 and newer and deliberately omitted on earlier servers.

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
The reusable implementation, evidence, and conformance method is documented in [`planning/strategy.md`](planning/strategy.md).

## Development

The project requires Lua 5.4 with 64-bit `lua_Integer`, LuaRocks, Copas 4.11, luaossl, Busted 2.3, Luacheck 1.2, and LuaCov 0.17. Install the rockspec's runtime and development dependencies, then run:

```sh
make test-unit
make test-integration
make test-unified
make test-unified-schema test-unified-inventory test-unified-meta test-unified-execution
make test-conformance
make test-quality
make test-compatibility
make lint
make check
```

Every target checks its prerequisites and explains how to select a missing tool through `LUA`, `LUAROCKS`, `BUSTED`, `LUACHECK`, `LUACOV`, or `PYTHON`. The unified execution gate needs `mongod` and, for its ephemeral replica set, `mongosh`; callers may instead supply dedicated deployments through the documented unified environment variables. External deployments set `MONGODB_UNIFIED_TEST_COMMANDS=1` when test commands are enabled; registered failpoint cases are otherwise explicitly reported as environment-skipped. The ephemeral gate enables test commands itself. `make test-unit` includes every pinned BSON and Extended JSON corpus representation, all 98 non-SRV connection-string fixtures plus their option-warning semantics, and the deterministic unified runner core. `make test-unified` separately runs all 320 JSON meta-fixtures, parses and schema-validates all 534 pinned integration files through the Lua Extended JSON and schema implementations, inventories their 2,521 tests, and reports execution status. The gate registers 1,263 exact cases, including 313 CRUD, monitoring, and failpoint cases, 243 retryable-read cases, 115 retryable-write cases, 164 explicit-transaction cases, 30 convenient-transaction cases, 304 client-side operation-timeout cases, 47 configuration cases, twenty-four MongoDB 8.2 `rawData` read/write/management cases, six clustered-index/time-series collection cases, three modify-collection error-response cases, one dropIndex default-concern case, four pre-8.0 write-sort cases, one estimated-count view case, and eight aggregate write-stage concern/preference cases. Version-incompatible branches are reported as environment skips, and the other 1,258 cases retain explicit owners. Integration coverage also includes real Copas/LuaSocket transport, verified and insecure LuaSec handshakes, public standalone and replica-set lifecycles, OP_MSG handshake, SCRAM-SHA-256 authentication, authenticated command execution, and reconnecting retry and transaction-control attempts.

`spec/compatibility/matrix.json` pins official MongoDB Community Server images by patch version and multi-architecture digest for MongoDB 7.0, 8.0, and 8.2. CI runs standalone and single-member replica-set rows for every series. Each row exercises plain, test-command, authentication, TLS, and authentication-plus-TLS profiles through both a public-client ping and an exact unified smoke test. It uploads a JSON report containing the observed server version, topology, security settings, image, gates, and separate passed, failed, and environment-skipped counts. Portable and loopback gates run independently on both Linux and macOS; the live compatibility deployments run from the pinned Docker images on Linux.

Validate the matrix without Docker using `make test-compatibility`. Replay one required live row on Linux with Docker host networking using, for example, `make test-compatibility-live COMPATIBILITY_ENTRY=mongodb-8.2-replicaset`. A missing Docker daemon is written as an environment skip only when `spec/compatibility/run.py` is invoked explicitly with `--allow-environment-skip`; CI never enables that option, so an unprovisioned advertised deployment cannot pass.

`make test-quality` runs the sorted, fixed-seed unit and integration suite under LuaCov and rejects any per-file or total line-coverage ratio below `spec/quality/coverage-baseline.json`. The current source baseline is 17,744 of 21,117 active lines (84.03%). It then replays 32 checked-in deterministic seeds through four rounds of cancellation, checkout, pool-clearing, monitoring, retry, and transaction-cleanup boundaries. Set `MONGODB_STRESS_SEED=N` to replay one schedule. A failure records its seed, iteration count, Lua version, and error in `build/quality/stress-failures.txt`.

The unified capability CLI verifies that every pinned integration test is runnable or explicitly classified. It supports repeatable fixture-path glob filters and versioned JSON reports:

```sh
python3 spec/unified/run.py
python3 spec/unified/run.py --include 'run-command/**' --report report.json
python3 spec/unified/validate_fixtures.py --schema-report schema.json --inventory-report inventory.json
python3 spec/unified/run_schema_meta.py --report meta.json
python3 spec/unified/update_capabilities.py --check
```

Schema, inventory, meta-runner, and execution reports have distinct types and counters. Per-test identities use the stable form `fixture/path.json::test[N]`; each of the 2,521 checked-in classifications carries a content fingerprint, extracted capability requirements, a roadmap owner, and a concrete reason when deferred. Execution reports distinguish passes, failures, environment skips, unsupported deferrals, scope exclusions, and invalid or incompatible inputs. Missing or stale tests, unknown capabilities, completed deferral owners, empty reasons, or regressions below the classified, runnable, and passing ratchets fail the command. A runnable test without an exact executor is reported as a failure.

`spec/release/scope.json` overlays the complete 5,524-case conformance ledger with the reviewed production-core boundary. It rejects ambiguous final-checkpoint owners and distinguishes 137 applicable gaps assigned to concrete release slices from 1,950 intentional post-v1 exclusions assigned to named capabilities. Atlas Search index helpers belong to the expanded administration API, while collection pre/post-image options remain with change streams; neither is hidden in the core release gap count. Regenerate the report only with the capability and conformance ledgers; `make test-conformance` rejects stale scope counts, completed gap owners, exclusions without a roadmap rationale, and any case assigned directly to the final release checkpoint.

`make test-conformance` checks the generated normative coverage ledger at `spec/conformance/ledger.json`. The ledger pins 2,966 JSON/YAML source files and 5,524 stable cases across 31 specification suites, including unified and legacy BSON, URI, SDAM, selection, CMAP, sessions, transactions, and timeout formats; 3,437 cases currently have passing evidence and 2,087 retain explicit owners. Each case records its fingerprint, format, runner, environment, milestone scope, status, last execution command, and roadmap owner. JSON is the canonical executable form where upstream also supplies equivalent YAML; both source files remain fingerprinted. Regenerate deliberately with `python3 spec/conformance/ledger.py`, while the normal gate uses `--check` so additions, removals, edits, missing owners, and stale coverage fail.

## Scope

The `production-core-v1` milestone covers standalone and replica-set CRUD, TLS and SCRAM, SDAM and CMAP, monitoring, sessions, retries, transactions, and client-side operation timeout. Advanced features such as change streams and their pre/post-image management, Atlas Search index helpers, GridFS, SRV, compression, sharded and load-balanced deployments, extra authentication mechanisms, and client bulk write remain post-v1. Client-side field-level/queryable encryption and GSSAPI require separate designs.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
