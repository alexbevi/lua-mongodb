# MongoDB Lua Driver

A pure-Lua MongoDB driver built directly from the [MongoDB driver specifications](https://github.com/mongodb/specifications), using a pinned [PyMongo](https://pymongo.readthedocs.io/en/stable/) source as a behavioral reference. The current release is version `0.4.0`; it adds snapshot sessions, Search index management, modern read/write concerns, and sharded discovery, monitoring, commands, and transactions to the authenticated production-core foundation. It targets Lua 5.4 without binding or wrapping `libmongoc`.

MongoDB specifications are normative. Architecture decisions live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), the reproducible implementation method lives in [`planning/strategy.md`](planning/strategy.md), and the executable roadmap lives in [`planning/plan.json`](planning/plan.json).

## Dependencies

- Lua 5.4 with a 64-bit `lua_Integer`.
- [Copas](https://lunarmodules.github.io/copas/) 4.11.x.
- [LuaSocket](https://lunarmodules.github.io/luasocket/) 3.1 or later, before 4.0.
- [LuaSec](https://github.com/lunarmodules/luasec) 1.3.x.
- [luaossl](https://github.com/wahern/luaossl) 20220711 or later.
- OpenSSL libraries and development headers required by the TLS and cryptography dependencies.

LuaRocks resolves the Lua dependencies declared by the rockspec. MongoDB Server is not a build dependency; the supported server versions and deployment types are listed under [Scope](#scope).

## Building and Installing

From a source checkout, build and install the release rock with:

```sh
luarocks make mongodb-0.4.0-1.rockspec
```

`make test-package` builds a source rock from the current checkout, installs it into an isolated LuaRocks tree, verifies that every production module is packaged, and exercises the documented public API without workspace module paths.

The public LuaRocks rock name is `mongodb`. Install version 0.4.0 with:

```sh
luarocks install mongodb 0.4.0-1
```

The release rockspec is built and verified from the immutable `v0.4.0` tag before publication.

## Getting Started

The driver runs network operations through a coroutine-aware runtime. For standalone programs, `mongodb.run` starts the default Copas scheduler and runs the application callback inside it. Applications that already own a Copas loop may create clients directly inside that loop instead. The examples use `assert` for brevity; production applications should handle the structured error returned as the second result of a failed operation.

### Connecting

Connect with a MongoDB URI, select the default database from that URI, and obtain a collection handle:

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

A library wrapping this driver may supply `driver_info = { name = "library", version = "1.2", platform = "Library Platform" }` when creating a client. It may later call `client:append_metadata()` with the same fields; each distinct tuple is appended to handshakes for new connections, while exact duplicates are ignored and established connections are unchanged.

For a DNS seedlist, use a `mongodb+srv` URI. Before opening a MongoDB socket, the driver resolves the URI hostname's SRV records and optional TXT defaults, validates every returned hostname against the URI's parent domain, and enables TLS unless the URI explicitly sets `tls=false` (or its `ssl` alias). Unknown and sharded topologies continue polling SRV records at the DNS TTL cadence, with a 60-second minimum, so mongos additions and removals do not require a client restart.

An ordinary one-seed URI may also point to mongos. The client discovers the sharded topology and executes ordinary and cursor commands through the monitored mongos pool.

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

For an LDAP-compatible deployment, select SASL PLAIN explicitly. Its authentication source defaults to the URI database, or `$external` when the URI has no database. Because PLAIN sends the password inside the TLS-protected SASL exchange, enable and validate TLS in production:

```lua
local client = assert(mongodb.client(
  "mongodb://user:password@directory.example.com/"
    .. "?authMechanism=PLAIN&tls=true"
))
```

### URI Options

URI option names use the standard MongoDB spelling and are case-insensitive. When the same setting is supplied in the client options table, the idiomatic `snake_case` client option takes precedence over the URI. The currently accepted URI options are grouped below.

| Area | URI options |
| --- | --- |
| DNS seedlist | `srvServiceName`, `srvMaxHosts` |
| TLS | `tls`/`ssl`, `tlsCAFile`, `tlsCertificateKeyFile`, `tlsCertificateKeyFilePassword`, `tlsInsecure`, `tlsAllowInvalidCertificates`, `tlsAllowInvalidHostnames`, `tlsDisableCertificateRevocationCheck`, `tlsDisableOCSPEndpointCheck` |
| Authentication and metadata | `appName`, `authSource`, `authMechanism`, `authMechanismProperties` |
| Connection and selection | `connectTimeoutMS`, `socketTimeoutMS`, `serverSelectionTimeoutMS`, `serverSelectionTryOnce`, `timeoutMS`, `localThresholdMS`, `heartbeatFrequencyMS`, `serverMonitoringMode`, `directConnection`, `replicaSet`, `loadBalanced` |
| Pooling | `maxPoolSize`, `minPoolSize`, `maxConnecting`, `maxIdleTimeMS`, `waitQueueTimeoutMS` |
| Reads, writes, and retries | `readPreference`, `readPreferenceTags`, `maxStalenessSeconds`, `readConcernLevel`, `w`, `journal`, `wTimeoutMS`, `retryReads`, `retryWrites` |

`serverMonitoringMode=auto` uses streaming monitoring except in a detected FaaS environment, where it uses polling. `stream` requests streaming on servers that support awaitable hello and falls back to polling on older servers; `poll` always waits `heartbeatFrequencyMS` after a successful check.

For `mongodb+srv`, `srvServiceName` changes the service label queried in `_service._tcp.hostname` and defaults to `mongodb`. `srvMaxHosts=0` (the default) keeps every valid SRV result; a positive value selects at most that many results and cannot be combined with `replicaSet` or `loadBalanced=true`. DNS may provide at most one TXT record containing only `authSource`, `replicaSet`, or `loadBalanced`; explicit URI or client options override those TXT defaults. Load-balanced deployment execution remains outside the current scope even though its connection-string option is recognized and validated.

### CRUD Operations

The remaining examples assume they run inside the `mongodb.run` callback above, before `client:close()`. MongoDB documents are represented by ordered BSON values. Collection methods return immutable result values with counts and generated identifiers. A cursor can be consumed with `:iter()` and closes automatically when exhausted.

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

For reporting reads, `aggregate` accepts an ordered BSON array of pipeline stages and returns the same cursor type as `find`. This pipeline filters active users, groups them by team, and orders the busiest teams first:

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

Once the example work is complete, delete the inserted document using its generated identifier:

```lua
local deleted = assert(users:delete_one(
  doc({ { "_id", inserted.inserted_id } })
))
print(deleted.deleted_count)
```

### Change Streams

On a replica set or sharded deployment, `collection:watch` opens a change stream for one collection. Its pipeline is appended after the required `$changeStream` stage. Stage options use `snake_case`, while batch size, collation, comments, maximum await time, and sessions follow the corresponding aggregate and cursor options. The returned stream yields change-event documents and owns its server cursor, so close it when iteration stops early. `next()` waits across empty live batches; `try_next()` performs at most one `getMore` and returns `nil` when that batch is empty so an application can cooperatively do other work. `resume_token()` returns the immutable token the driver would use to resume after the latest returned document or empty batch.

```lua
local events = assert(users:watch(mongodb.bson.array({
  doc({ { "$match", doc({ { "operationType", "insert" } }) } }),
}), {
  batch_size = 10,
  full_document = "updateLookup",
  max_await_time_ms = 1000,
}))

local change = assert(events:next())
print(change:get("operationType"))
assert(events:resume_token())
assert(events:close())
```

### Bulk Operations

Bulk writes combine insert, update, replace, and delete models. The driver batches those models within server limits and merges their results. Ordered execution stops at the first write error; use `{ ordered = false }` when independent models may continue after an error.

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

### Generic Commands

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

### Index Management

`collection:create_index` creates one index from an ordered key document and returns its name. Use `mongodb.index_model` with `collection:create_indexes` to create several indexes together; `list_indexes`, `drop_index`, and `drop_indexes` manage existing indexes. Key directions may be ascending (`1`), descending (`-1`), `text`, `hashed`, `2d`, `2dsphere`, or `geoHaystack`.

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

#### Search Indexes

`collection:create_search_index` creates one standard or vector Search index and returns the server-reported name. `collection:create_search_indexes` accepts an ordered Lua array of those models and returns the corresponding immutable name list. `collection:list_search_indexes` returns a cursor over every Search index or an optional name filter and accepts the normal aggregation options. `collection:update_search_index` replaces the definition of a named Search index, and `collection:drop_search_index` idempotently removes one by name. A model is an ordered BSON document with a required `definition` and optional `name` and `type` fields.

```lua
local search_name = assert(users:create_search_index(doc({
  { "definition", doc({
    { "mappings", doc({ { "dynamic", true } }) },
  }) },
  { "name", "users-search" },
  { "type", "search" },
})))
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

The public surface currently includes ordered BSON and Extended JSON values; client, database, collection, cursor, and session handles; standalone, replica-set, and mongos connections; SCRAM, PLAIN, X.509, and TLS; generic database commands; CRUD and collection bulk writes; collection and index management; monitoring; retries; transactions; and client-side operation timeout.

### Errors and resource lifetimes

Operational methods return a value on success or `nil, err` with a structured error on failure. Errors expose stable categories, labels, timeout and retryability flags, and server details without including protected command values in diagnostic strings.

Clients, cursors, and sessions have explicit idempotent close methods. Closing a client releases its owned cursors, sessions, connection pools, monitor tasks, connections, and sockets; applications should still close resources as soon as their useful lifetime ends.

## Specification compatibility

Compatibility is projected from the checked-in [conformance ledger](spec/conformance/ledger.json) and [accepted-specification catalog](spec/conformance/catalog.json), not from implementation claims. Machine-fixture rows use ledger cases; named prose-only rows use their catalog requirement outcomes. A suite is green only when every support-scored outcome passes, yellow when passing and unsupported outcomes remain, and red when no support-scored outcome passes. Tracked support % is the share of support-scored outcomes whose status is `passed`; `not_applicable` and `no_machine_cases` outcomes are excluded, and a suite containing only those outcomes displays N/A. The table is generated by `planning/update_readme_compatibility.py` and must not be edited manually.

The ordering follows the "onion model" classification of [MongoDB driver specifications](https://alexbevi.com/specifications/), from serialization at the core through communication, connectivity, authentication, availability, resilience, programmability, observability, and testability.

> [!NOTE]
> Legend:\
> 🟢 Fully Implemented / Validated\
> 🟡 Partially Implemented\
> 🔴 Not Implemented\
> ⚪ No support-scored requirement / Not applicable

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status | Tracked support % |
| --- | --- | :---: | ---: |
| Serialization | BSON corpus | 🟢 | 100.0% |
| Serialization | BSON binary vector | 🟢 | 100.0% |
| Communication | Connection string | 🟢 | 100.0% |
| Communication | URI options | 🟡 | 78.6% |
| Communication | Handshake metadata propagation | 🟢 | 100.0% |
| Communication | Initial DNS seedlist discovery | 🟡 | 83.0% |
| Communication | OCSP support | 🔴 | 0.0% |
| Communication | Wire compression | 🔴 | 0.0% |
| Communication | SOCKS5 proxy support | 🔴 | 0.0% |
| Communication | Command execution | 🟡 | 85.7% |
| Connectivity | Server discovery and monitoring | 🟡 | 96.1% |
| Connectivity | Connection monitoring and pooling | 🟡 | 82.5% |
| Connectivity | Load balancer support | 🔴 | 0.0% |
| Authentication | Authentication options and additional mechanisms | 🟡 | 83.6% |
| Availability | Server selection | 🟡 | 90.4% |
| Availability | Max staleness | 🟢 | 100.0% |
| Availability | Periodic SRV polling | 🟢 | 100.0% |
| Resilience | Retryable reads | 🟡 | 70.5% |
| Resilience | Retryable writes | 🟡 | 93.7% |
| Resilience | Client-side operations timeout | 🟡 | 64.9% |
| Resilience | Sessions | 🟢 | 100.0% |
| Resilience | Causal consistency | 🟡 | 94.4% |
| Resilience | Transactions | 🟡 | 93.8% |
| Resilience | Convenient transactions API | 🟢 | 100.0% |
| Programmability | CRUD | 🟡 | 71.5% |
| Programmability | Collection management | 🟡 | 81.8% |
| Programmability | Index management | 🟢 | 100.0% |
| Programmability | Read/write concern | 🟡 | 98.0% |
| Programmability | Change streams | 🟡 | 6.7% |
| Programmability | GridFS | 🔴 | 0.0% |
| Programmability | Stable API | 🟡 | 92.7% |
| Programmability | Client-side encryption | 🔴 | 0.0% |
| Observability | Command logging and monitoring | 🟡 | 13.8% |
| Observability | Standardized logging | 🔴 | 0.0% |
| Observability | Client backpressure | 🔴 | 0.0% |
| Observability | OpenTelemetry | 🔴 | 0.0% |
| Testability | Unified test format | 🟢 | 100.0% |
| Testability | Atlas SFP testing | 🔴 | 0.0% |
<!-- END SPEC CONFORMANCE -->

## Scope

The `production-core-v1` milestone targets:

- Lua 5.4 with a 64-bit `lua_Integer` and the Copas 4.11 runtime adapter.
- MongoDB Community Server 7.0, 8.0, and 8.2.
- Standalone and replica-set deployments.
- TLS, SCRAM, SDAM, CMAP, server selection, CRUD, monitoring, sessions, retries, transactions, and client-side operation timeout.

The v0.4 conformance surface adds snapshot sessions, Search index management, modern read/write-concern behavior, and sharded discovery, monitoring, command execution, and transaction pinning. All 851 applicable cases in that declared surface are classified passing; 47 non-target cases retain explicit later owners or a target-version exclusion. Other post-v1 scope includes change streams, GridFS, wire compression, load-balanced deployments, client bulk write, additional authentication mechanisms, observability extensions, proxy support, and client-side encryption.

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
