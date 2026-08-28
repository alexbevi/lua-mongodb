# MongoDB Lua driver

A coroutine-aware MongoDB driver written in Lua without binding or wrapping `libmongoc`. It supports Lua 5.4 and Lua 5.5, standalone servers, [replica sets](https://www.mongodb.com/docs/manual/replication/), [sharded clusters](https://www.mongodb.com/docs/manual/sharding/), and load-balanced deployments. The [MongoDB driver specifications](https://github.com/mongodb/specifications) define its behavior, with a pinned [PyMongo](https://pymongo.readthedocs.io/en/stable/) checkout as a reference.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for design decisions, [`planning/strategy.md`](planning/strategy.md) for the implementation method, and [`planning/plan.json`](planning/plan.json) for the roadmap.

Report potential vulnerabilities privately through the repository's [security policy](SECURITY.md).
Development setup and review expectations are in the [contribution guide](CONTRIBUTING.md).

## Dependencies

- Lua 5.4 or Lua 5.5 with a 64-bit `lua_Integer`.
- [Copas](https://lunarmodules.github.io/copas/) 4.11.x or 4.12.x.
- [LuaSocket](https://lunarmodules.github.io/luasocket/) 3.1 or later, before 4.0.
- [LuaSec](https://github.com/lunarmodules/luasec) 1.3.x.
- `getpid` 0.1.0, `sha1` 0.5, `md5` 1.3, `lua-cryptorandom` 0.0.6, and `lua-zlib` 1.4 or compatible releases.
- Optional Snappy and Zstandard compression use `lua-csnappy` 0.1.5 and `lua-zstd` 0.2 or compatible releases. `lua-zstd` also needs the Zstandard library and development headers.
- OpenSSL libraries and development headers required by the TLS dependency and by `lua-cryptorandom` on supported Unix-like platforms.

LuaRocks resolves the Lua dependencies declared by the rockspec. MongoDB Server is not a build dependency.

Install either optional provider separately when needed:

```sh
luarocks install lua-csnappy
luarocks install lua-zstd
```

## Platform support

The release rock and default Copas runtime are verified on Linux and macOS. Windows and other untested operating systems are not supported. Platform services such as clocks, networking, TLS, and entropy stay behind the runtime adapter. A custom runtime adapter is an extension point, not a platform support claim. Supporting another operating system requires recurring package and network CI.

## Building and installing

Install the latest public release from LuaRocks with:

```sh
luarocks install mongodb
```

From a source checkout, build and install the checked-in rockspec with:

```sh
luarocks make
```

`make test-package` builds a source rock, installs it in an isolated LuaRocks tree, and checks its modules and public API without workspace paths.

Release rockspecs are built and verified from immutable release tags before publication.

The [API reference and stability policy](docs/API.md) lists supported public and runtime-extension entry points. Packaged internal modules are not public API.

## Specification compatibility

`planning/update_readme_compatibility.py` generates this table from the [conformance ledger](spec/conformance/ledger.json) and [accepted-specification catalog](spec/conformance/catalog.json). Green means every scored outcome passes. Yellow means passed and incomplete outcomes coexist. Red means no scored outcome passes.

Tracked support % divides passes by scored outcomes. It omits `not_applicable`, `no_machine_cases`, terminal `unsupported`, explicit unscored exclusions, and unified fixtures restricted to MongoDB versions older than the supported 7.0 floor. A bold dagger marks percentages with omitted fixtures. A suite with no scored outcomes displays N/A, and the white badge marks a suite the project will not implement. The total combines all displayed outcomes rather than averaging suite percentages.

The "onion model" orders the [MongoDB driver specifications](https://alexbevi.com/specifications/) with serialization first and testability last.

> [!NOTE]
> Legend:\
> 🟢 Fully Implemented / Validated\
> 🟡 Partially Implemented\
> 🔴 Not Implemented\
> ⚪ Will Not Implement

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status | Tracked support % |
| --- | --- | :---: | ---: |
| Serialization | [BSON corpus](https://alexbevi.com/specifications/bson-corpus/bson-corpus.html) | 🟢 | 100.0% |
| Serialization | [BSON binary vector](https://alexbevi.com/specifications/bson-binary-vector/bson-binary-vector.html) | 🟢 | 100.0% |
| Communication | [Connection string](https://alexbevi.com/specifications/connection-string/connection-string-spec.html) | 🟢 | 100.0% |
| Communication | [URI options](https://alexbevi.com/specifications/uri-options/uri-options.html) | 🟡 | 95.8% |
| Communication | [Handshake metadata propagation](https://alexbevi.com/specifications/mongodb-handshake/handshake.html) | 🟢 | 100.0% |
| Communication | [Initial DNS seedlist discovery](https://alexbevi.com/specifications/initial-dns-seedlist-discovery/initial-dns-seedlist-discovery.html) | 🟢 | 100.0% |
| Communication | [OCSP support](https://alexbevi.com/specifications/ocsp-support/ocsp-support.html) | ⚪ | N/A |
| Communication | [Wire compression](https://alexbevi.com/specifications/compression/OP_COMPRESSED.html) | 🟢 | 100.0% |
| Communication | [SOCKS5 proxy support](https://alexbevi.com/specifications/socks5-support/socks5.html) | ⚪ | N/A |
| Communication | [Command execution](https://alexbevi.com/specifications/run-command/run-command.html) | 🟢 | 100.0% |
| Connectivity | [Server discovery and monitoring](https://alexbevi.com/specifications/server-discovery-and-monitoring/server-discovery-and-monitoring.html) | 🟡 | 98.9% **†** |
| Connectivity | [Connection monitoring and pooling](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🟡 | 87.5% |
| Connectivity | [Load balancer support](https://alexbevi.com/specifications/load-balancers/load-balancers.html) | 🟢 | 100.0% **†** |
| Authentication | [Authentication options and additional mechanisms](https://alexbevi.com/specifications/auth/auth.html) | 🟢 | 100.0% **†** |
| Availability | [Server selection](https://alexbevi.com/specifications/server-selection/server-selection.html) | 🟢 | 100.0% |
| Availability | [Max staleness](https://alexbevi.com/specifications/max-staleness/max-staleness.html) | 🟢 | 100.0% |
| Availability | [Periodic SRV polling](https://alexbevi.com/specifications/polling-srv-records-for-mongos-discovery/polling-srv-records-for-mongos-discovery.html) | 🟢 | 100.0% |
| Resilience | [Retryable reads](https://alexbevi.com/specifications/retryable-reads/retryable-reads.html) | 🟢 | 100.0% |
| Resilience | [Retryable writes](https://alexbevi.com/specifications/retryable-writes/retryable-writes.html) | 🟢 | 100.0% **†** |
| Resilience | [Client-side operations timeout](https://alexbevi.com/specifications/client-side-operations-timeout/client-side-operations-timeout.html) | 🟡 | 99.4% |
| Resilience | [Sessions](https://alexbevi.com/specifications/sessions/driver-sessions.html) | 🟢 | 100.0% **†** |
| Resilience | [Causal consistency](https://alexbevi.com/specifications/causal-consistency/causal-consistency.html) | 🟢 | 100.0% |
| Resilience | [Transactions](https://alexbevi.com/specifications/transactions/transactions.html) | 🟡 | 96.5% |
| Resilience | [Convenient transactions API](https://alexbevi.com/specifications/transactions-convenient-api/transactions-convenient-api.html) | 🟢 | 100.0% |
| Programmability | [CRUD](https://alexbevi.com/specifications/crud/crud.html) | 🟢 | 100.0% **†** |
| Programmability | [Collection management](https://alexbevi.com/specifications/enumerate-collections/enumerate-collections.html) | 🟢 | 100.0% |
| Programmability | [Index management](https://alexbevi.com/specifications/index-management/index-management.html) | 🟢 | 100.0% |
| Programmability | [Read/write concern](https://alexbevi.com/specifications/read-write-concern/read-write-concern.html) | 🟢 | 100.0% |
| Programmability | [Change streams](https://alexbevi.com/specifications/change-streams/change-streams.html) | 🟢 | 100.0% **†** |
| Programmability | [GridFS](https://alexbevi.com/specifications/gridfs/gridfs-spec.html) | 🟢 | 100.0% |
| Programmability | [Stable API](https://alexbevi.com/specifications/versioned-api/versioned-api.html) | 🟢 | 100.0% |
| Programmability | [Client-side encryption](https://alexbevi.com/specifications/client-side-encryption/client-side-encryption.html) | 🔴 | 0.0% **†** |
| Observability | [Command logging and monitoring](https://alexbevi.com/specifications/command-logging-and-monitoring/command-logging-and-monitoring.html) | 🟢 | 100.0% **†** |
| Observability | [Standardized logging](https://alexbevi.com/specifications/logging/logging.html) | 🟢 | 100.0% |
| Observability | [Client backpressure](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🔴 | 0.0% |
| Observability | [OpenTelemetry](https://alexbevi.com/specifications/open-telemetry/open-telemetry.html) | 🔴 | 0.0% |
| Testability | [Unified test format](https://alexbevi.com/specifications/unified-test-format/unified-test-format.html) | 🟢 | 100.0% |
|  | **Total** |  | **82.9%** **†** |

> [!IMPORTANT]
> **† Fixtures excluded from scoring.**
>
> Percentages marked **†** skip 106 upstream fixtures because their `runOnRequirements` restrict them to MongoDB versions older than the supported 7.0 floor. The affected suites are CRUD (74), Change streams (19), Command logging and monitoring (4), Retryable writes (3), Sessions (3), Server discovery and monitoring (2), and Client-side encryption (1). These fixtures remain classified in the conformance ledger but do not count toward the marked suite percentages or the total.
>
> The ledger also omits 3 explicit superseded or upstream-skipped fixtures from Authentication options and additional mechanisms (2), Load balancer support (1).
<!-- END SPEC CONFORMANCE -->

## Getting started

Network operations run inside a coroutine-aware runtime. In a standalone program, `mongodb.run` owns the default Copas loop and invokes the application callback. An application with its own Copas loop can create clients inside that loop. Run the shorter constructor examples in one of these loops. The examples use `assert` for brevity; production code should handle the structured error returned as the second result of a failed operation.

### Connecting

Connect with a [MongoDB URI](https://www.mongodb.com/docs/manual/reference/connection-string/), select the default database from that URI, and obtain a collection handle:

```lua
local mongodb = require("mongodb")

mongodb.run(function()
  local client = assert(mongodb.client("mongodb://localhost:27017/app"))
  local users = client:database():collection("users")
  local result = assert(users:insert_one(
    mongodb.bson.document({ { "name", "Ada" } })
  ))
  local user = assert(users:find_one(result.inserted_id))

  print(user:get("name"))
  assert(client:close())
end)
```

Set the handshake application name with the URI `appName` option or the `app_name` client option. Names can be up to 128 bytes and appear only in the initial handshake on each new socket.

For a DNS seedlist, use a `mongodb+srv` URI. The driver resolves SRV records and optional TXT defaults, rejects hostnames outside the URI's parent domain, and enables TLS unless the URI sets `tls=false` or `ssl=false`. Unknown and sharded topologies poll SRV records at the DNS TTL, with a 60-second minimum.

A one-seed URI may also point to mongos. The client discovers and monitors the sharded topology.

Set `loadBalanced=true` when connecting to a load-balanced endpoint. The client then uses a service-aware pool and keeps cursor and [transaction](https://www.mongodb.com/docs/manual/core/transactions/) connections pinned when required.

```lua
local mongodb = require("mongodb")

mongodb.run(function()
  local client = assert(mongodb.client(
    "mongodb+srv://cluster.example.com/app?replicaSet=rs0"
  ))
  local reply = assert(client:database("admin"):run_command(
    mongodb.bson.document({ { "ping", 1 } })
  ))

  print(reply:get("ok"))
  assert(client:close())
end)
```

Wire compression is opt-in and negotiated per connection. List Zstandard, Snappy, or zlib in preference order with `compressors`. The driver advertises Zstandard and Snappy only when their providers are installed and reports missing providers in `client.warnings`. `zlibCompressionLevel` accepts `-1` through `9`. A connection with no common compressor remains usable; handshake, [authentication](https://www.mongodb.com/docs/manual/core/authentication/), and user-management commands stay uncompressed.

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/app?compressors=zstd,snappy,zlib&zlibCompressionLevel=6"
))
```

#### Authentication

Select an authentication mechanism with MongoDB URI options. Structured errors redact credentials and tokens. Workload mechanisms resolve credentials when a connection authenticates.

**SCRAM.** A username and password select SCRAM automatically. The driver prefers SCRAM-SHA-256 and falls back to SCRAM-SHA-1. Set `authMechanism` to require one version, and percent-encode reserved characters in credentials.

```lua
local client = assert(mongodb.client(
  "mongodb://app-user:secret@db.example.com/app?authSource=admin"
))
```

**X.509.** Provide a client certificate/private-key PEM through the TLS adapter and select `MONGODB-X509`. The certificate subject is used as the username when the URI omits one.

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/?authMechanism=MONGODB-X509",
  {
    tls = true,
    tls_ca_file = "/path/to/ca.pem",
    tls_certificate_key_file = "/path/to/client.pem",
  }
))
```

**OIDC.** `MONGODB-OIDC` has built-in `azure`, `gcp`, and `k8s` environments plus programmatic machine and human callbacks. This Kubernetes example reads the service-account token through the runtime adapter.

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/app?authMechanism=MONGODB-OIDC"
    .. "&authMechanismProperties=ENVIRONMENT:k8s"
))
```

For callback-based OIDC, set one function-valued `OIDC_CALLBACK` or `OIDC_HUMAN_CALLBACK` in `auth_mechanism_properties`. `ALLOWED_HOSTS` works only with a human callback and otherwise defaults to the MongoDB service domains and local loopback hosts. Azure and GCP require `TOKEN_RESOURCE`.

**MONGODB-AWS.** Select `MONGODB-AWS` without putting credentials in the URI. The driver checks `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN`, followed by web identity, ECS credentials, and EC2 metadata.

```lua
local client = assert(mongodb.client(
  "mongodb+srv://cluster.example.com/app?authMechanism=MONGODB-AWS"
))
```

**GSSAPI.** Live authentication is verified with Lua 5.4 on Ubuntu 24.04. The default runtime loads the operating system's GSSAPI library on Linux or macOS when available, but macOS and Lua 5.5 do not yet have recurring live authentication coverage. Omit the password to use the Kerberos ticket cache. Password credentials require support from the installed library. Each connection owns its GSSAPI context.

```lua
local client = assert(mongodb.client(
  "mongodb://user%40EXAMPLE.COM@db.example.com/"
    .. "?authMechanism=GSSAPI"
    .. "&authMechanismProperties=SERVICE_NAME:mongodb"
))
```

For an LDAP-compatible deployment, select SASL PLAIN. Its authentication source defaults to the URI database, or `$external` when the URI has no database. PLAIN relies on TLS to protect the password, so enable and validate TLS in production:

```lua
local client = assert(mongodb.client(
  "mongodb://user:password@directory.example.com/"
    .. "?authMechanism=PLAIN&tls=true"
))
```

### URI options

URI option names use MongoDB spelling and are case-insensitive. A `snake_case` client option overrides the same URI setting. The driver accepts:

| Area | URI options |
| --- | --- |
| DNS seedlist | `srvServiceName`, `srvMaxHosts` |
| TLS | `tls`/`ssl`, `tlsCAFile`, `tlsCertificateKeyFile`, `tlsCertificateKeyFilePassword`, `tlsInsecure`, `tlsAllowInvalidCertificates`, `tlsAllowInvalidHostnames`, `tlsDisableCertificateRevocationCheck`, `tlsDisableOCSPEndpointCheck` |
| Authentication and metadata | `appName`, `authSource`, `authMechanism`, `authMechanismProperties` |
| Connection and selection | `connectTimeoutMS`, `socketTimeoutMS`, `serverSelectionTimeoutMS`, `serverSelectionTryOnce`, `timeoutMS`, `localThresholdMS`, `heartbeatFrequencyMS`, `serverMonitoringMode`, `directConnection`, `replicaSet`, `loadBalanced` |
| Wire compression | `compressors`, `zlibCompressionLevel` |
| Pooling | `maxPoolSize`, `minPoolSize`, `maxConnecting`, `maxIdleTimeMS`, `waitQueueTimeoutMS` |
| Reads, writes, and retries | `readPreference`, `readPreferenceTags`, `maxStalenessSeconds`, `readConcernLevel`, `w`, `journal`, `wTimeoutMS`, `retryReads`, `retryWrites` |

> [!IMPORTANT]
> OCSP is not supported. The driver cannot perform certificate revocation checking for Atlas if it uses OCSP-only certificates, or for deployments whose certificate authority issues OCSP-only certificates.
>
> SOCKS5 proxy transport is not supported. The `proxyHost`, `proxyPort`, `proxyUsername`, and `proxyPassword` options are unavailable.

`serverMonitoringMode=auto` uses streaming except in a detected FaaS environment. `stream` falls back to polling when a server lacks awaitable hello support. `poll` waits `heartbeatFrequencyMS` after each successful check.

For `mongodb+srv`, `srvServiceName` sets the `_service._tcp.hostname` service label and defaults to `mongodb`. `srvMaxHosts=0` keeps every valid SRV result. A positive limit cannot be combined with `replicaSet` or `loadBalanced=true`. DNS may supply one TXT record containing `authSource`, `replicaSet`, or `loadBalanced`; URI and client options override it.

### Structured logging

Logging is off by default. Set a minimum severity with `MONGODB_LOG_ALL` or configure `MONGODB_LOG_COMMAND`, `MONGODB_LOG_CONNECTION`, `MONGODB_LOG_SERVER_SELECTION`, and `MONGODB_LOG_TOPOLOGY` separately. Levels are `emergency`, `alert`, `critical`, `error`, `warn`, `notice`, `info`, `debug`, and `trace`; `off` disables a component. `MONGODB_LOG_PATH` accepts `stdout` or `stderr`, and `MONGODB_LOG_MAX_DOCUMENT_LENGTH` defaults to 1000. Invalid environment values are ignored.

The client `logging` table accepts `levels`, `destination`, and `max_document_length`, or a `sink` callback in place of a destination. Programmatic values override environment values:

```lua
local client = assert(mongodb.client("mongodb://localhost:27017/app", {
  logging = {
    levels = { all = "warn", command = "debug" },
    destination = "stderr",
    max_document_length = 2000,
  },
}))
```

The `command` component emits start, success, and failure messages at `debug` and redacts sensitive command documents. The `connection`, `server_selection`, and `topology` settings are accepted but do not emit messages yet.

### CRUD operations

These [CRUD](https://www.mongodb.com/docs/manual/crud/) examples run inside the earlier `mongodb.run` callback, before `client:close()`. [MongoDB documents](https://www.mongodb.com/docs/manual/core/document/) use ordered [BSON values](https://www.mongodb.com/docs/manual/reference/bson-types/). Collection methods return immutable results. `cursor:iter()` closes an exhausted cursor but cannot report iteration errors; use `cursor:next()` when errors matter.

```lua
local doc = mongodb.bson.document
local users = client:database("app"):collection("users")

local inserted = assert(users:insert_one(doc({
  { "name", "Ada" },
  { "team", "compilers" },
  { "active", false },
})))

local user = assert(users:find_one(inserted.inserted_id))
print(user:get("name"))

local updated = assert(users:update_one(
  doc({ { "_id", inserted.inserted_id } }),
  doc({ { "$set", doc({ { "active", true } }) } })
))
print(updated.modified_count)

local cursor = assert(users:find(
  doc({ { "active", true } }),
  { sort = doc({ { "name", 1 } }) }
))

for matching_user in cursor:iter() do
  print(matching_user:get("name"))
end
```

For a capped collection, set `cursor_type = "tailable"`, or use `tailable_await` to let the server wait for data. Each `next()` checks at most one batch. An empty live batch returns `nil` without closing the cursor. `max_await_time_ms` bounds each server wait and must be lower than a positive `timeout_ms`:

```lua
local events = client:database("app"):collection("events")
local cursor = assert(events:find(nil, { cursor_type = "tailable" }))
local event, err = cursor:next()

assert(not err, err)

if event then
  print(event)
end

assert(cursor:close())
```

`aggregate` accepts an ordered BSON array of [pipeline](https://www.mongodb.com/docs/manual/core/aggregation-pipeline/) stages and returns a cursor. This pipeline counts active users by team:

```lua
local active_users_by_team = assert(users:aggregate(mongodb.bson.array({
  doc({ { "$match", doc({ { "active", true } }) } }),
  doc({ { "$group", doc({
    { "_id", "$team" },
    { "user_count", doc({ { "$sum", 1 } }) },
  }) } }),
  doc({ { "$sort", doc({ { "user_count", -1 } }) } }),
})))

for team in active_users_by_team:iter() do
  print(team:get("_id"), team:get("user_count"))
end
```

Use `database:aggregate` for pipelines that do not target one collection.

Use `collection:count_documents` for an exact query count and `collection:estimated_document_count` for a metadata estimate. The compatibility-only `collection:count` method sends the legacy command and can be inaccurate during sharded migrations.

The compatibility-only `collection:map_reduce` accepts JavaScript strings or `mongodb.bson.code` values. Prefer aggregation pipelines in new code.

Delete the inserted document by its generated identifier:

```lua
local deleted = assert(users:delete_one(
  doc({ { "_id", inserted.inserted_id } })
))
print(deleted.deleted_count)
```

### Change streams

On a replica set or sharded deployment, `collection:watch` opens a [change stream](https://www.mongodb.com/docs/manual/changeStreams/) for one collection. `database:watch` covers a database, and `client:watch` covers the cluster. `next()` waits across empty batches, while `try_next()` checks once and may return `nil` on a live stream. `timeout_ms` applies separately to opening and each iteration, and `max_await_time_ms` must be lower than a positive timeout. The driver attempts one resume after a resumable read failure. Close a stream when iteration stops early.

```lua
local events = assert(users:watch(mongodb.bson.array({
  doc({ { "$match", doc({ { "operationType", "insert" } }) } }),
}), {
  batch_size = 10,
  full_document = "updateLookup",
  max_await_time_ms = 1000,
  timeout_ms = 5000,
}))

local change = assert(events:next())
print(change:get("operationType"))
assert(events:resume_token())
assert(events:close())

local database_events = assert(client:database("app"):watch())
assert(database_events:close())

local cluster_events = assert(client:watch())
assert(cluster_events:close())
```

### Bulk operations

[Bulk writes](https://www.mongodb.com/docs/manual/core/bulk-write-operations/) combine insert, update, replace, and delete models. The driver batches models within server limits and merges their results. Ordered execution stops at the first write error; set `ordered = false` to continue independent models.

```lua
local doc = mongodb.bson.document
local bulk = mongodb.bulk

local written = assert(users:bulk_write({
  bulk.insert_one(doc({ { "name", "Grace" }, { "active", false } })),
  bulk.update_one(
    doc({ { "name", "Grace" } }),
    doc({ { "$set", doc({ { "active", true } }) } })
  ),
  bulk.delete_one(doc({ { "name", "Retired account" } })),
}, { ordered = true }))

print(written.inserted_count)
print(written.modified_count)
print(written.deleted_count)
```

Collection bulk options include `ordered`, `bypass_document_validation`, `comment`, and `let`. Write concern comes from the collection handle.

MongoDB 8.0 and newer support client bulk writes across namespaces. These use separate `mongodb.client_bulk` models. `timeout_ms` covers every batch, eligible retries, and internal result-cursor cleanup.

```lua
local client_bulk = mongodb.client_bulk

local written = assert(client:bulk_write({
  client_bulk.insert_one(
    "app.users",
    doc({ { "name", "Grace" } })
  ),
  client_bulk.update_one(
    "app.users",
    doc({ { "name", "Grace" } }),
    doc({ { "$set", doc({ { "active", true } }) } })
  ),
  client_bulk.replace_one(
    "audit.events",
    doc({ { "kind", "user-created" } }),
    doc({ { "kind", "user-activated" } })
  ),
  client_bulk.delete_many(
    "audit.events",
    doc({ { "expired", true } })
  ),
}))

print(written.inserted_count)
print(written.modified_count)
print(written.deleted_count)
```

Set `verbose_results = true` to add immutable `insert_results`, `update_results`, and `delete_results` maps keyed by each model's original 1-based position. Client bulk options also accept `ordered`, `bypass_document_validation`, `comment`, `let`, and an operation-level `write_concern`. An unacknowledged write concern requires `ordered = false` and summary results.

A client bulk failure returns `nil` and a structured write error. `details.write_errors` follows original model order, and `details.partial_result` reports confirmed successes when any exist.

### Generic commands

`database:run_command` returns one reply. Use `database:run_cursor_command` when the reply owns a server cursor. Its `batch_size`, `max_await_time_ms`, and `comment` options apply to later `getMore` commands.

```lua
local db = client:database("app")
local cursor = assert(db:run_cursor_command(
  mongodb.bson.document({ { "find", "users" }, { "batchSize", 1 } }),
  { batch_size = 5 }
))

for user in cursor:iter() do
  print(user:get("name"))
end
```

### Index management

`collection:create_index` creates one [index](https://www.mongodb.com/docs/manual/indexes/) from an ordered key document and returns its name. Use `mongodb.index_model` with `create_indexes` for a batch. `list_indexes`, `drop_index`, and `drop_indexes` manage existing indexes. Valid directions are `1`, `-1`, `text`, `hashed`, `2d`, `2dsphere`, and `geoHaystack`.

Index options include `collation`, `hidden`, `partial_filter_expression`, `sparse`, `expire_after_seconds`, and `unique`. See MongoDB's [index properties guide](https://www.mongodb.com/docs/manual/core/indexes/index-properties/) for valid combinations.

This example creates a case-insensitive unique index only for active users:

```lua
local email_index = assert(users:create_index(doc({ { "email", 1 } }), {
  name = "active_email_unique",
  unique = true,
  partial_filter_expression = doc({ { "active", true } }),
  collation = doc({ { "locale", "en" }, { "strength", 2 } }),
}))

print(email_index)
```

#### Search indexes

`collection:create_search_index` creates a standard or vector [Search index](https://www.mongodb.com/docs/search/index/manage-indexes/) and returns its server-reported name. A model is a BSON document with `definition` plus optional `name` and `type` fields. The collection also supports batch creation, listing, update, and drop methods.

```lua
local search_name = assert(users:create_search_index(doc({
  { "definition", doc({
    { "mappings", doc({ { "dynamic", true } }) },
  }) },
  { "name", "users-search" },
  { "type", "search" },
})))
```

### GridFS

[GridFS](https://www.mongodb.com/docs/manual/core/gridfs/) stores files in BSON chunks. A bucket can upload a byte string, query file documents, and open a download stream by id. Download streams support `read`, `seek`, `tell`, and `close`.

```lua
local bucket = assert(client:database("app"):gridfs_bucket())
local file_id = assert(bucket:upload_from_stream(
  "greeting.txt",
  "Hello from GridFS!"
))
local download = assert(bucket:open_download_stream(file_id))

assert(download:seek("set", 6) == 6)
local greeting = assert(download:read())
assert(download:close())
print(greeting) -- from GridFS!

local doc = mongodb.bson.document
local files = assert(bucket:find(
  doc({ { "filename", "greeting.txt" } }),
  { sort = doc({ { "uploadDate", -1 } }), limit = 3 }
))

for file in files:iter() do
  print(file:get("filename"))
end
```

### Transactions

Transactions require a replica set or sharded deployment. The driver implements both APIs from the [MongoDB transaction guide](https://www.mongodb.com/docs/manual/core/transactions-in-applications/):

- `with_transaction` handles start, commit, abort, and required retries. Keep its callback safe to run more than once.
- `start_transaction`, `commit_transaction`, and `abort_transaction` expose direct control for custom error handling.

Pass the active session to every operation with either API.

#### Callback API

```lua
local doc = mongodb.bson.document
local accounts = client:database("bank"):collection("accounts")
local session = assert(client:start_session())

local transferred = assert(session:with_transaction(function(active_session)
  assert(accounts:update_one(
    doc({ { "_id", "checking" } }),
    doc({ { "$inc", doc({ { "balance", -100 } }) } }),
    { session = active_session }
  ))
  assert(accounts:update_one(
    doc({ { "_id", "savings" } }),
    doc({ { "$inc", doc({ { "balance", 100 } }) } }),
    { session = active_session }
  ))
  return true
end, {
  read_concern = doc({ { "level", "snapshot" } }),
  write_concern = doc({ { "w", "majority" } }),
}))

assert(transferred)
assert(session:end_session())
```

#### Core API

```lua
local doc = mongodb.bson.document
local accounts = client:database("bank"):collection("accounts")
local session = assert(client:start_session())

local function transfer()
  local started, err = session:start_transaction({
    read_concern = doc({ { "level", "snapshot" } }),
    write_concern = doc({ { "w", "majority" } }),
  })

  if not started then
    return nil, err
  end

  local updated
  updated, err = accounts:update_one(
    doc({ { "_id", "checking" } }),
    doc({ { "$inc", doc({ { "balance", -100 } }) } }),
    { session = session }
  )

  if updated then
    updated, err = accounts:update_one(
      doc({ { "_id", "savings" } }),
      doc({ { "$inc", doc({ { "balance", 100 } }) } }),
      { session = session }
    )
  end

  if not updated then
    local aborted, abort_err = session:abort_transaction()
    return nil, aborted and err or abort_err
  end

  return session:commit_transaction()
end

local transferred, err = transfer()
assert(session:end_session())
assert(transferred, err)
```

`client:start_session` accepts `causal_consistency`, `snapshot`, `snapshot_time`, `default_transaction_options`, and `timeout_ms`. Snapshot sessions disable causal consistency and require MongoDB 5.0 or newer. `session:get_snapshot_time()` returns the timestamp chosen by the first snapshot read, an explicit `snapshot_time`, or `nil` before one exists.

### Errors and resource lifetimes

Operational methods return a value on success or `nil, err` on failure. Structured errors include a category, labels, timeout and retryability flags, and server details without protected command values.

Clients, cursors, and sessions have idempotent close methods. Close resources promptly; client close is the final cleanup for its cursors, sessions, pools, monitors, connections, and sockets.

## Examples

The [`examples`](examples/README.md) use the public LuaRocks package for connection setup, BSON data, transactions, and two-window LÖVE Pong driven by change streams. They do not load modules from the source checkout.

## Development

After cloning, initialize the pinned normative and reference repositories:

```sh
git submodule update --init --recursive
python3 planning/update_plan.py check --strict --pushed
python3 planning/update_plan.py next
```

The main verification targets are:

```sh
make test-unit
make test-integration
make test-unified
make test-conformance
make test-quality
make test-compatibility
make test-package
make lint
make check
```

For a local change, run the narrow selector-driven target:

```sh
make test-focus FOCUS_UNIT=spec/unit/config_options_spec.lua \
  FOCUS_LINT="src/mongodb/config/options.lua spec/unit/config_options_spec.lua"
```

Use `FOCUS_INTEGRATION`, `FOCUS_UNIFIED`, or `FOCUS_PYTHON` for other boundaries. GitHub Actions runs portable gates and representative live rows after each push. Full Conformance owns complete unified, coverage, and server/topology compatibility checks.

See [`planning/README.md`](planning/README.md) for roadmap commands and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for implementation details and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
