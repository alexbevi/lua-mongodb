# MongoDB Lua driver

A coroutine-aware MongoDB driver written in Lua without binding or wrapping `libmongoc`. It supports Lua 5.4 and Lua 5.5, standalone servers, [replica sets](https://www.mongodb.com/docs/manual/replication/), [sharded clusters](https://www.mongodb.com/docs/manual/sharding/), and load-balanced deployments. The implementation follows the [MongoDB driver specifications](https://github.com/mongodb/specifications), with a pinned [PyMongo](https://pymongo.readthedocs.io/en/stable/) checkout as its behavioral reference.

MongoDB specifications are normative. Architecture decisions live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), the reproducible implementation method lives in [`planning/strategy.md`](planning/strategy.md), and the executable roadmap lives in [`planning/plan.json`](planning/plan.json).

Report potential vulnerabilities privately through the repository's [security policy](SECURITY.md).
Development setup and review expectations are in the [contribution guide](CONTRIBUTING.md).

## Dependencies

- Lua 5.4 or Lua 5.5 with a 64-bit `lua_Integer`.
- [Copas](https://lunarmodules.github.io/copas/) 4.11.x or 4.12.x.
- [LuaSocket](https://lunarmodules.github.io/luasocket/) 3.1 or later, before 4.0.
- [LuaSec](https://github.com/lunarmodules/luasec) 1.3.x.
- `getpid` 0.1.0, `sha1` 0.5, `md5` 1.3, `lua-cryptorandom` 0.0.6, and `lua-zlib` 1.4 or compatible releases.
- Optional Snappy and Zstandard wire compression use `lua-csnappy` 0.1.5 and `lua-zstd` 0.2 or compatible releases; `lua-zstd` also requires the Zstandard library and development headers.
- OpenSSL libraries and development headers required by the TLS dependency and by `lua-cryptorandom` on supported Unix-like platforms.

LuaRocks resolves the Lua dependencies declared by the rockspec. MongoDB Server is not a build dependency.

Install either optional provider separately when needed:

```sh
luarocks install lua-csnappy
luarocks install lua-zstd
```

## Platform support

The release rock and default Copas runtime are verified on Linux and macOS. Windows and other
untested operating systems are not supported. The pure-Lua driver core still reaches clocks,
networking, TLS, entropy, and other platform services through the runtime boundary. A custom
runtime adapter is an extension point, not a platform support claim. A new operating system
becomes supported only after its dependencies, package installation, runtime behavior, and
network integration are covered by recurring project CI.

## Building and installing

Install the latest public release from LuaRocks with:

```sh
luarocks install mongodb
```

From a source checkout, build and install the checked-in rockspec with:

```sh
luarocks make
```

`make test-package` builds a source rock from the current checkout, installs it into an isolated LuaRocks tree, verifies that every production module is packaged, and exercises the documented public API without workspace module paths.

Release rockspecs are built and verified from immutable release tags before publication.

The [API reference and stability policy](docs/API.md) identifies supported public and
runtime-extension entry points. Modules installed as implementation dependencies are not public
merely because they can be loaded with `require`.

## Getting started

The driver runs network operations through a coroutine-aware runtime. For standalone programs, `mongodb.run` starts the default Copas scheduler and runs the application callback inside it. Applications that already own a Copas loop may create clients directly inside that loop instead. The examples use `assert` for brevity; production applications should handle the structured error returned as the second result of a failed operation.

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

Set the optional handshake application name with the URI `appName` option or the idiomatic `app_name` client option. Names are limited to 128 bytes. The driver sends that name with its fixed driver identity and runtime OS/platform facts only in the initial handshake on each newly established socket.

For a DNS seedlist, use a `mongodb+srv` URI. Before opening a MongoDB socket, the driver resolves the URI hostname's SRV records and optional TXT defaults, validates every returned hostname against the URI's parent domain, and enables TLS unless the URI explicitly sets `tls=false` (or its `ssl` alias). Unknown and sharded topologies continue polling SRV records at the DNS TTL cadence, with a 60-second minimum, so mongos additions and removals do not require a client restart.

An ordinary one-seed URI may also point to mongos. The client discovers the sharded topology and executes ordinary and cursor commands through the monitored mongos pool.

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

Wire compression is opt-in and negotiated independently on every connection. Enable Zstandard, Snappy, or zlib with the `compressors` option; when several compressors are listed, their order defines client preference. Zstandard and Snappy are advertised only when their optional providers are installed, and an unavailable configured provider is reported in `client.warnings`. `zlibCompressionLevel` accepts `-1` (the default) through `9`. A server with no common compressor remains usable without compression, while handshake, [authentication](https://www.mongodb.com/docs/manual/core/authentication/), and user-management commands always remain uncompressed.

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/app?compressors=zstd,snappy,zlib&zlibCompressionLevel=6"
))
```

#### Authentication

Select an authentication mechanism with standard MongoDB URI options. Credentials and tokens are kept out of structured errors, and runtime-backed mechanisms resolve workload credentials when a connection authenticates.

**SCRAM.** A username and password use SCRAM automatically: the driver negotiates SCRAM-SHA-256 when the server supports it and otherwise falls back to SCRAM-SHA-1. Use `authMechanism` to require a specific version, and percent-encode reserved characters in credentials.

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

**OIDC.** `MONGODB-OIDC` supports the `azure`, `gcp`, and `k8s` built-in environments, as well as programmatic machine and human callbacks. This Kubernetes example reads the service-account token through the runtime adapter.

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/app?authMechanism=MONGODB-OIDC"
    .. "&authMechanismProperties=ENVIRONMENT:k8s"
))
```

For callback-based OIDC, configure exactly one function-valued `OIDC_CALLBACK` or `OIDC_HUMAN_CALLBACK` in the programmatic `auth_mechanism_properties` table. `ALLOWED_HOSTS` is accepted only with a human callback; when omitted, it defaults to the MongoDB service domains and local loopback hosts required by the authentication specification. Azure and GCP environments require `TOKEN_RESOURCE`.

**MONGODB-AWS.** Select `MONGODB-AWS` without embedding credentials in the URI. At authentication time the driver checks `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and optional `AWS_SESSION_TOKEN` first; without them, it uses configured web-identity or ECS credentials, then EC2 metadata.

```lua
local client = assert(mongodb.client(
  "mongodb+srv://cluster.example.com/app?authMechanism=MONGODB-AWS"
))
```

**GSSAPI.** Live authentication is verified with Lua 5.4 on Ubuntu 24.04. The default runtime can load the operating system's GSSAPI library on Linux and macOS, but macOS and Lua 5.5 remain unclaimed until they have recurring live profiles. Omit the password to use the current Kerberos ticket cache. Password credentials are accepted only when the installed library reports that capability. Each application connection owns its GSSAPI context, including during concurrent authentication.

```lua
local client = assert(mongodb.client(
  "mongodb://user%40EXAMPLE.COM@db.example.com/"
    .. "?authMechanism=GSSAPI"
    .. "&authMechanismProperties=SERVICE_NAME:mongodb"
))
```

For an LDAP-compatible deployment, select SASL PLAIN explicitly. Its authentication source defaults to the URI database, or `$external` when the URI has no database. Because PLAIN sends the password inside the TLS-protected SASL exchange, enable and validate TLS in production:

```lua
local client = assert(mongodb.client(
  "mongodb://user:password@directory.example.com/"
    .. "?authMechanism=PLAIN&tls=true"
))
```

### URI options

URI option names use the standard MongoDB spelling and are case-insensitive. When the same setting is supplied in the client options table, the idiomatic `snake_case` client option takes precedence over the URI. The driver accepts these URI options:

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

`serverMonitoringMode=auto` uses streaming monitoring except in a detected FaaS environment, where it uses polling. `stream` requests streaming on servers that support awaitable hello and falls back to polling on older servers; `poll` always waits `heartbeatFrequencyMS` after a successful check.

For `mongodb+srv`, `srvServiceName` changes the service label queried in `_service._tcp.hostname` and defaults to `mongodb`. `srvMaxHosts=0` (the default) keeps every valid SRV result; a positive value selects at most that many results and cannot be combined with `replicaSet` or `loadBalanced=true`. DNS may provide at most one TXT record containing only `authSource`, `replicaSet`, or `loadBalanced`; explicit URI or client options override those TXT defaults.

### Structured logging

Logging is off by default. Enable a minimum severity for every component with
`MONGODB_LOG_ALL`, or set `MONGODB_LOG_COMMAND`, `MONGODB_LOG_CONNECTION`,
`MONGODB_LOG_SERVER_SELECTION`, and `MONGODB_LOG_TOPOLOGY` independently. Accepted levels,
from most to least severe, are `emergency`, `alert`, `critical`, `error`, `warn`, `notice`,
`info`, `debug`, and `trace`; `off` disables a component. `MONGODB_LOG_PATH` accepts `stdout`
or `stderr`, and `MONGODB_LOG_MAX_DOCUMENT_LENGTH` defaults to 1000. Invalid environment
values are ignored without preventing client construction.

The client `logging` option provides the same controls with `levels`, `destination`, and
`max_document_length`. It can also accept a `sink` callback instead of a destination.
Programmatic values take precedence over environment values:

```lua
local client = assert(mongodb.client("mongodb://localhost:27017/app", {
  logging = {
    levels = { all = "warn", command = "debug" },
    destination = "stderr",
    max_document_length = 2000,
  },
}))
```

The configuration, sink, and structured event envelope are available independently of component
emission. Command, server-selection, topology, and connection messages are introduced by their
component-specific releases.

An application that wants the standard environment variable to override its own default can
read it before constructing the client:

```lua
local client = assert(mongodb.client("mongodb://localhost:27017/app", {
  logging = {
    levels = { all = os.getenv("MONGODB_LOG_ALL") or "warn" },
  },
}))
```

### CRUD operations

The following examples of [CRUD operations](https://www.mongodb.com/docs/manual/crud/) assume they run inside the `mongodb.run` callback above, before `client:close()`. [MongoDB documents](https://www.mongodb.com/docs/manual/core/document/) are represented by ordered [BSON values](https://www.mongodb.com/docs/manual/reference/bson-types/). Collection methods return immutable result values with counts and generated identifiers. A cursor can be consumed with `:iter()` and closes automatically when exhausted.

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

For a capped collection, pass `cursor_type = "tailable"` to `find`, or use
`cursor_type = "tailable_await"` to let the server wait for new data before
returning an empty batch. Each `next()` call checks at most one server batch,
so an empty live batch returns `nil` without closing the cursor and the
application can poll again later. Set `max_await_time_ms` to bound each server
wait; when `timeout_ms` is also positive, the maximum await time must be lower
than that client timeout:

```lua
local events = client:database("app"):collection("events")
local cursor = assert(events:find(nil, { cursor_type = "tailable" }))
local event = cursor:next()

if event then
  print(event)
end

assert(cursor:close())
```

For reporting reads, `aggregate` accepts an ordered BSON array of [aggregation pipeline](https://www.mongodb.com/docs/manual/core/aggregation-pipeline/) stages and returns the same cursor type as `find`. This pipeline filters active users, groups them by team, and orders the busiest teams first:

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

Database-level pipelines use `database:aggregate` and return the same cursor type. For example, an administrative pipeline can enumerate one local session without naming a collection:

```lua
local sessions = assert(client:database("admin"):aggregate(mongodb.bson.array({
  doc({ { "$listLocalSessions", doc({}) } }),
  doc({ { "$limit", 1 } }),
})))

for session_document in sessions:iter() do
  print(session_document)
end
```

For counts, prefer `collection:count_documents(filter, options)` for an exact query count or `collection:estimated_document_count(options)` for a fast metadata estimate. The deprecated `collection:count(filter, options)` method remains available for compatibility and sends the legacy `count` command directly; its result can be inaccurate on a sharded cluster while orphaned documents or chunk migrations are present.

The deprecated `collection:map_reduce(map, reduce, out, options)` helper accepts JavaScript strings or `mongodb.bson.code` values. An inline output document such as `doc({ { "inline", 1 } })` returns the result documents as a BSON array; output-producing forms return the server's result collection name or document. Prefer aggregation pipelines for new applications.

Once the example work is complete, delete the inserted document using its generated identifier:

```lua
local deleted = assert(users:delete_one(
  doc({ { "_id", inserted.inserted_id } })
))
print(deleted.deleted_count)
```

### Change streams

On a replica set or sharded deployment, `collection:watch` opens a [change stream](https://www.mongodb.com/docs/manual/changeStreams/) for one collection, `database:watch` observes every collection in that database, and `client:watch` observes every database in the cluster. Their pipeline is appended after the required `$changeStream` stage. Stage options use `snake_case`, while batch size, collation, comments, maximum await time, and sessions follow the corresponding aggregate and cursor options. `database:create_collection` and `database:modify_collection` accept the ordered `change_stream_pre_and_post_images` document supported by MongoDB 6.0 and later. `collection:rename` accepts a destination name plus optional `drop_target`, `comment`, and `session`, and applies the collection's inherited write concern. The returned stream yields change-event documents and owns its server cursor, so close it when iteration stops early. `next()` waits across empty live batches; `try_next()` performs at most one `getMore` and returns `nil` when that batch is empty so an application can cooperatively do other work. `timeout_ms` limits stream establishment and each iteration separately; one iteration budget covers both `getMore` and any resume attempt. A positive timeout requires a lower `max_await_time_ms`, which is further bounded by the remaining timeout budget. A timed-out stream remains usable, and its next iteration attempts to resume it. `resume_token()` returns the immutable token the driver would use to resume after the latest returned document or empty batch. A resumable iteration failure recreates the stream once, preserving `start_after` until the first event and otherwise using the cached token or qualifying `start_at_operation_time`; terminal errors and a failed recreation are returned directly.

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

assert(users:rename("archived_users", {
  comment = "archive users",
  drop_target = true,
}))
```

### Bulk operations

[Bulk writes](https://www.mongodb.com/docs/manual/core/bulk-write-operations/) combine insert, update, replace, and delete models. The driver batches those models within server limits and merges their results. Ordered execution stops at the first write error; use `{ ordered = false }` when independent models may continue after an error.

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

Pass `{ verbose_results = true }` to populate immutable `insert_results`, `update_results`, and `delete_results` maps keyed by each model's original 1-based position. Summary results omit those maps. Command options also accept `ordered`, `bypass_document_validation`, `comment`, `let`, and an operation-level `write_concern`; an operation concern overrides the client default.

MongoDB 8.0 and newer also accept one client-level bulk command spanning several namespaces. Client bulk models are separate from collection bulk models. The API supports insert, update-one, update-many, replacement, delete-one, and delete-many models and returns immutable summary or verbose results. Set `timeout_ms` to bound the complete client bulk operation, including all batches, one retry, and result-cursor cleanup. An unacknowledged `write_concern = { w = 0 }` requires `ordered = false` and no verbose results; its immutable result exposes `acknowledged = false` without count or per-model result fields.

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

An individual client bulk failure returns `nil` and a structured write error. Its immutable `details.write_errors` array is ordered by the models' original 1-based positions; each entry exposes the server code, message, optional `errInfo` details, and failed wire operation. Ordered execution reports its first individual failure, while unordered execution reports every observed individual failure. When at least one model is known to have succeeded, `details.partial_result` exposes the same immutable summary or verbose result shape; it is absent when the first ordered model or every unordered model failed.

### Generic commands

`database:run_command` returns one command reply. For a command whose reply owns a server cursor, use `database:run_cursor_command`; it executes the initial command eagerly and returns the same cursor type used by collection reads. Its `batch_size`, `max_await_time_ms`, and `comment` options apply to subsequent `getMore` commands.

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

`collection:create_index` creates one [index](https://www.mongodb.com/docs/manual/indexes/) from an ordered key document and returns its name. Use `mongodb.index_model` with `collection:create_indexes` to create several indexes together; `list_indexes`, `drop_index`, and `drop_indexes` manage existing indexes. Key directions may be ascending (`1`), descending (`-1`), `text`, `hashed`, `2d`, `2dsphere`, or `geoHaystack`.

MongoDB's [index properties guide](https://www.mongodb.com/docs/manual/core/indexes/index-properties/) covers case-insensitive, hidden, partial, sparse, TTL, and unique indexes. Configure those properties with `collation`, `hidden`, `partial_filter_expression`, `sparse`, `expire_after_seconds`, and `unique`, respectively. Not every property is compatible with every index type; MongoDB validates the final combination.

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

`collection:create_search_index` creates one standard or vector [Search index](https://www.mongodb.com/docs/search/index/manage-indexes/) and returns the server-reported name. `collection:create_search_indexes` accepts an ordered Lua array of those models and returns the corresponding immutable name list. `collection:list_search_indexes` returns a cursor over every Search index or an optional name filter and accepts the normal aggregation options. `collection:update_search_index` replaces the definition of a named Search index, and `collection:drop_search_index` idempotently removes one by name. A model is an ordered BSON document with a required `definition` and optional `name` and `type` fields.

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

[GridFS](https://www.mongodb.com/docs/manual/core/gridfs/) stores files in bounded BSON chunks. Upload from a byte string, query
stored file documents through a cursor, then open an immutable download stream
by id. Download streams support bounded `read` calls plus the standard Lua
`seek`, `tell`, and `close` methods.

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

Transactions require a replica-set-backed deployment, reached directly with a URI such as `mongodb://localhost:27017/bank?replicaSet=rs0` or through one or more mongos routers. The driver provides both APIs described in the [MongoDB transaction API guide](https://www.mongodb.com/docs/manual/core/transactions-in-applications/):

- **Callback API:** `with_transaction` owns start, commit, abort, and the specification retries for transient transaction and unknown commit-result errors. Prefer it for most transactions, and keep the callback safe to run more than once.
- **Core API:** `start_transaction`, `commit_transaction`, and `abort_transaction` expose the lifecycle directly. Use it when the application needs custom control over error handling and retries.

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

`client:start_session` accepts `causal_consistency`, `snapshot`, `snapshot_time`, `default_transaction_options`, and `timeout_ms`. Snapshot sessions default causal consistency off, reject an explicit `causal_consistency = true`, require `snapshot = true` when initialized with a BSON timestamp through `snapshot_time`, reject command execution against servers older than MongoDB 5.0, and send snapshot read concern on every command. The first snapshot read captures its server timestamp for every later command; an explicit `snapshot_time` is used from the first command. `session:get_snapshot_time()` reads that immutable BSON timestamp and returns `nil` when the session has no snapshot time.

### Errors and resource lifetimes

Operational methods return a value on success or `nil, err` with a structured error on failure. Errors expose stable categories, labels, timeout and retryability flags, and server details without including protected command values in diagnostic strings.

Clients, cursors, and sessions have explicit idempotent close methods. Closing a client releases its owned cursors, sessions, connection pools, monitor tasks, connections, and sockets; applications should still close resources as soon as their useful lifetime ends.

## Examples

The self-contained [`examples`](examples/README.md) learning path installs the public LuaRocks driver and covers connection setup, BSON application modeling, transactions, and a two-window LÖVE Pong demo driven by change streams. The examples do not add source-checkout module paths.

## Specification compatibility

Compatibility comes from the checked-in [conformance ledger](spec/conformance/ledger.json) and [accepted-specification catalog](spec/conformance/catalog.json). Machine-fixture rows use ledger cases, and named prose-only rows use catalog requirement outcomes. A suite is green when every support-scored outcome passes, yellow when passes and incomplete scored outcomes coexist, and red when no scored outcome passes. Tracked support % divides passed outcomes by all scored outcomes. The calculation omits `not_applicable`, `no_machine_cases`, and terminal `unsupported` outcomes. A suite containing only omitted outcomes displays N/A; the white badge marks a suite the project will not implement. The total uses the same calculation across all displayed scored outcomes instead of averaging suite percentages. `planning/update_readme_compatibility.py` generates the table.

The ordering follows the "onion model" classification of [MongoDB driver specifications](https://alexbevi.com/specifications/), from serialization at the core through communication, connectivity, authentication, availability, resilience, programmability, observability, and testability.

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
| Connectivity | [Server discovery and monitoring](https://alexbevi.com/specifications/server-discovery-and-monitoring/server-discovery-and-monitoring.html) | 🟡 | 96.7% |
| Connectivity | [Connection monitoring and pooling](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🟡 | 82.5% |
| Connectivity | [Load balancer support](https://alexbevi.com/specifications/load-balancers/load-balancers.html) | 🟡 | 97.5% |
| Authentication | [Authentication options and additional mechanisms](https://alexbevi.com/specifications/auth/auth.html) | 🟡 | 97.6% |
| Availability | [Server selection](https://alexbevi.com/specifications/server-selection/server-selection.html) | 🟡 | 90.4% |
| Availability | [Max staleness](https://alexbevi.com/specifications/max-staleness/max-staleness.html) | 🟢 | 100.0% |
| Availability | [Periodic SRV polling](https://alexbevi.com/specifications/polling-srv-records-for-mongos-discovery/polling-srv-records-for-mongos-discovery.html) | 🟢 | 100.0% |
| Resilience | [Retryable reads](https://alexbevi.com/specifications/retryable-reads/retryable-reads.html) | 🟢 | 100.0% |
| Resilience | [Retryable writes](https://alexbevi.com/specifications/retryable-writes/retryable-writes.html) | 🟢 | 100.0% |
| Resilience | [Client-side operations timeout](https://alexbevi.com/specifications/client-side-operations-timeout/client-side-operations-timeout.html) | 🟡 | 99.4% |
| Resilience | [Sessions](https://alexbevi.com/specifications/sessions/driver-sessions.html) | 🟢 | 100.0% |
| Resilience | [Causal consistency](https://alexbevi.com/specifications/causal-consistency/causal-consistency.html) | 🟢 | 100.0% |
| Resilience | [Transactions](https://alexbevi.com/specifications/transactions/transactions.html) | 🟡 | 96.5% |
| Resilience | [Convenient transactions API](https://alexbevi.com/specifications/transactions-convenient-api/transactions-convenient-api.html) | 🟢 | 100.0% |
| Programmability | [CRUD](https://alexbevi.com/specifications/crud/crud.html) | 🟡 | 85.2% |
| Programmability | [Collection management](https://alexbevi.com/specifications/enumerate-collections/enumerate-collections.html) | 🟢 | 100.0% |
| Programmability | [Index management](https://alexbevi.com/specifications/index-management/index-management.html) | 🟢 | 100.0% |
| Programmability | [Read/write concern](https://alexbevi.com/specifications/read-write-concern/read-write-concern.html) | 🟢 | 100.0% |
| Programmability | [Change streams](https://alexbevi.com/specifications/change-streams/change-streams.html) | 🟡 | 78.7% |
| Programmability | [GridFS](https://alexbevi.com/specifications/gridfs/gridfs-spec.html) | 🟢 | 100.0% |
| Programmability | [Stable API](https://alexbevi.com/specifications/versioned-api/versioned-api.html) | 🟢 | 100.0% |
| Programmability | [Client-side encryption](https://alexbevi.com/specifications/client-side-encryption/client-side-encryption.html) | 🔴 | 0.0% |
| Observability | [Command logging and monitoring](https://alexbevi.com/specifications/command-logging-and-monitoring/command-logging-and-monitoring.html) | 🟡 | 61.5% |
| Observability | [Standardized logging](https://alexbevi.com/specifications/logging/logging.html) | 🟢 | 100.0% |
| Observability | [Client backpressure](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🔴 | 0.0% |
| Observability | [OpenTelemetry](https://alexbevi.com/specifications/open-telemetry/open-telemetry.html) | 🔴 | 0.0% |
| Testability | [Unified test format](https://alexbevi.com/specifications/unified-test-format/unified-test-format.html) | 🟢 | 100.0% |
|  | **Total** |  | **80.6%** |
<!-- END SPEC CONFORMANCE -->

## Development

After cloning, initialize the pinned normative and reference repositories:

```sh
git submodule update --init --recursive
python3 planning/update_plan.py check --strict --pushed
python3 planning/update_plan.py next
```

The standard verification gates are:

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

For ordinary local changes, prefer the narrow selector-driven target instead of the full gate:

```sh
make test-focus FOCUS_UNIT=spec/unit/example_spec.lua \
  FOCUS_LINT="src/mongodb/example.lua spec/unit/example_spec.lua"
```

Use `FOCUS_INTEGRATION`, `FOCUS_UNIFIED`, or `FOCUS_PYTHON` for the directly affected boundary. GitHub Actions runs the fast portable gates plus representative standalone, replica-set, and sharded compatibility rows after each push; the Full Conformance workflow runs complete unified and coverage gates plus all nine server/topology compatibility rows before release and on its schedule.

See [`planning/README.md`](planning/README.md) for roadmap commands and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for implementation details and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
