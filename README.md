# MongoDB Lua Driver

A pure-Lua MongoDB driver built directly from the [MongoDB driver specifications](https://github.com/mongodb/specifications), using a pinned [PyMongo](https://pymongo.readthedocs.io/en/stable/) source as a behavioral reference. Production-core v1 is version `0.1.0`. It targets Lua 5.4 without binding or wrapping `libmongoc`.

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
luarocks make mongodb-0.1.0-1.rockspec
```

`make test-package` builds a source rock from the current checkout, installs it into an isolated LuaRocks tree, verifies that every production module is packaged, and exercises the documented public API without workspace module paths.

The public LuaRocks rock name is `mongodb`. After version 0.1.0 is published, users will be able to install it with:

```sh
luarocks install mongodb 0.1.0-1
```

The release rockspec is ready in this source tree; publication to LuaRocks is a separate release operation.

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

### Transactions

Transactions require a client connected with a replica-set URI such as `mongodb://localhost:27017/bank?replicaSet=rs0`. `with_transaction` starts, commits, and applies the specification retry rules for transient failures. Pass the active session to every operation in the transaction, and keep the callback safe to run more than once.

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

The public surface currently includes ordered BSON and Extended JSON values; client, database, collection, cursor, and session handles; standalone and replica-set connections; SCRAM and TLS; generic database commands; CRUD and collection bulk writes; collection and index management; monitoring; retries; transactions; and client-side operation timeout.

### Errors and resource lifetimes

Operational methods return a value on success or `nil, err` with a structured error on failure. Errors expose stable categories, labels, timeout and retryability flags, and server details without including protected command values in diagnostic strings.

Clients, cursors, and sessions have explicit idempotent close methods. Closing a client releases its owned cursors, sessions, connection pools, monitor tasks, connections, and sockets; applications should still close resources as soon as their useful lifetime ends.

## Specification compatibility

Compatibility is projected from the checked-in [conformance ledger](spec/conformance/ledger.json), not from implementation claims. A suite is green only when every tracked case passes, yellow when passing and unsupported cases remain, and red when no tracked case passes. Tests Passing % is the share of all tracked cases whose ledger status is `passed`. The table is generated by `planning/update_readme_compatibility.py` and must not be edited manually.

The ordering follows the "onion model" classification of [MongoDB driver specifications](https://alexbevi.com/specifications/), from serialization at the core through communication, connectivity, authentication, availability, resilience, programmability, observability, and testability.

> [!NOTE]
> Legend:\
> 🟢 Fully Implemented / Validated\
> 🟡 Partially Implemented\
> 🔴 Not Implemented

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status | Tests Passing % |
| --- | --- | :---: | ---: |
| Serialization | BSON corpus | 🟢 | 100.0% |
| Serialization | BSON binary vector | 🟢 | 100.0% |
| Communication | Connection string | 🟢 | 100.0% |
| Communication | URI options | 🟡 | 78.6% |
| Communication | Handshake metadata propagation | 🟢 | 100.0% |
| Communication | Initial DNS seedlist discovery | 🔴 | 0.0% |
| Communication | Command execution | 🟡 | 81.0% |
| Connectivity | Server discovery and monitoring | 🟡 | 89.1% |
| Connectivity | Connection monitoring and pooling | 🟡 | 82.5% |
| Connectivity | Load balancer support | 🔴 | 0.0% |
| Authentication | Authentication options and additional mechanisms | 🔴 | 0.0% |
| Availability | Server selection | 🟡 | 90.4% |
| Availability | Max staleness | 🟢 | 100.0% |
| Resilience | Retryable reads | 🟡 | 70.3% |
| Resilience | Retryable writes | 🟡 | 93.7% |
| Resilience | Client-side operations timeout | 🟡 | 64.9% |
| Resilience | Sessions | 🟡 | 28.2% |
| Resilience | Causal consistency | 🟡 | 94.4% |
| Resilience | Transactions | 🟡 | 64.3% |
| Resilience | Convenient transactions API | 🟢 | 100.0% |
| Programmability | CRUD | 🟡 | 71.5% |
| Programmability | Collection management | 🟡 | 81.8% |
| Programmability | Index management | 🟡 | 10.5% |
| Programmability | Read/write concern | 🟡 | 98.0% |
| Programmability | Change streams | 🔴 | 0.0% |
| Programmability | GridFS | 🔴 | 0.0% |
| Programmability | Stable API | 🟡 | 92.7% |
| Programmability | Client-side encryption | 🔴 | 0.0% |
| Observability | Command logging and monitoring | 🟡 | 13.8% |
| Observability | Client backpressure | 🔴 | 0.0% |
| Observability | OpenTelemetry | 🔴 | 0.0% |
| Testability | Unified test format | 🟢 | 100.0% |
<!-- END SPEC CONFORMANCE -->

## Scope

The `production-core-v1` milestone targets:

- Lua 5.4 with a 64-bit `lua_Integer` and the Copas 4.11 runtime adapter.
- MongoDB Community Server 7.0, 8.0, and 8.2.
- Standalone and replica-set deployments.
- TLS, SCRAM, SDAM, CMAP, server selection, CRUD, monitoring, sessions, retries, transactions, and client-side operation timeout.

Post-v1 scope includes change streams, GridFS, SRV discovery, wire compression, sharded and load-balanced deployments, client bulk write, additional authentication mechanisms, observability extensions, proxy support, and client-side encryption.

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

Use `FOCUS_INTEGRATION`, `FOCUS_UNIFIED`, or `FOCUS_PYTHON` for the directly affected boundary. GitHub Actions runs the fast portable and compatibility-boundary gates after each push; the Full Conformance workflow runs complete unified, coverage, and compatibility gates before release and on its schedule.

See [`planning/README.md`](planning/README.md) for roadmap commands and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for implementation details and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
