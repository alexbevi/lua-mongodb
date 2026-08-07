# MongoDB Lua Driver

A pure-Lua MongoDB driver built directly from the MongoDB driver specifications, with the pinned PyMongo source as a behavioral reference. The project is pre-alpha and targets Lua 5.4 without binding or wrapping `libmongoc`.

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

From a source checkout, build and install the development rock with:

```sh
luarocks make mongodb-scm-1.rockspec
```

The planned public LuaRocks rock name is `mongodb`. After the first release is published, users will be able to install it with:

```sh
luarocks install mongodb
```

The project is currently pre-alpha, and no release has been published under that name yet.

## Getting Started

The driver runs network operations through a coroutine-aware runtime. With the default Copas adapter, create and use clients inside `copas.loop`. The examples use `assert` for brevity; production applications should handle the structured error returned as the second result of a failed operation.

### Connecting

Connect with a MongoDB URI, select the default database from that URI, and obtain a collection handle:

```lua
local copas = require("copas")
local mongodb = require("mongodb")

copas.loop(function()
  local client = assert(mongodb.client("mongodb://localhost:27017/app", {
    runtime = mongodb.runtime.copas(),
  }))
  local users = client:database():collection("users")
  local result = assert(users:insert_one(
    mongodb.bson.document({ { "name", "Ada" } })
  ))
  local user = assert(users:find_one(result.inserted_id))

  print(user:get("name"))
  assert(client:close())
end)
```

### CRUD Operations

The remaining examples assume they run inside the Copas loop above, before `client:close()`. MongoDB documents are represented by ordered BSON values. Collection methods return immutable result values with counts and generated identifiers. A cursor can be consumed with `:iter()` and closes automatically when exhausted.

```lua
local doc = mongodb.bson.document
local users = client:database("app"):collection("users")

local inserted = assert(users:insert_one(doc({
  { "name", "Ada" },
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

The public surface currently includes ordered BSON and Extended JSON values; client, database, collection, cursor, and session handles; standalone and replica-set connections; SCRAM and TLS; CRUD and collection bulk writes; collection and index management; monitoring; retries; transactions; and client-side operation timeout.

## Specification compatibility

Compatibility is projected from the checked-in [conformance ledger](spec/conformance/ledger.json), not from implementation claims. A suite is green only when every tracked case passes, yellow when passing and unsupported cases remain, and red when no tracked case passes. The table is generated by `planning/update_readme_compatibility.py` and must not be edited manually.

The ordering follows the [MongoDB driver specifications onion model](https://alexbevi.com/specifications/), from serialization at the core through communication, connectivity, authentication, availability, resilience, programmability, observability, and testability.

Legend: 🟢 Green = Fully Implemented / Validated · 🟡 Yellow = Partially Implemented · 🔴 Red = Not Implemented

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status |
| --- | --- | :---: |
| Serialization | BSON corpus | 🟢 |
| Serialization | BSON binary vector | 🟢 |
| Communication | Connection string | 🟢 |
| Communication | URI options | 🟡 |
| Communication | Handshake metadata propagation | 🔴 |
| Communication | Initial DNS seedlist discovery | 🔴 |
| Communication | Command execution | 🟡 |
| Connectivity | Server discovery and monitoring | 🟡 |
| Connectivity | Connection monitoring and pooling | 🟡 |
| Connectivity | Load balancer support | 🔴 |
| Authentication | Authentication options and additional mechanisms | 🔴 |
| Availability | Server selection | 🟡 |
| Availability | Max staleness | 🟢 |
| Resilience | Retryable reads | 🟡 |
| Resilience | Retryable writes | 🟡 |
| Resilience | Client-side operations timeout | 🟡 |
| Resilience | Sessions | 🟡 |
| Resilience | Causal consistency | 🟡 |
| Resilience | Transactions | 🟡 |
| Resilience | Convenient transactions API | 🟢 |
| Programmability | CRUD | 🟡 |
| Programmability | Collection management | 🟡 |
| Programmability | Index management | 🟡 |
| Programmability | Read/write concern | 🟡 |
| Programmability | Change streams | 🔴 |
| Programmability | GridFS | 🔴 |
| Programmability | Stable API | 🟡 |
| Programmability | Client-side encryption | 🔴 |
| Observability | Command logging and monitoring | 🔴 |
| Observability | Client backpressure | 🔴 |
| Observability | OpenTelemetry | 🔴 |
| Testability | Unified test format | 🟢 |
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
make lint
make check
```

For ordinary local changes, prefer the narrow selector-driven target instead of the full gate:

```sh
make test-focus FOCUS_UNIT=spec/unit/example_spec.lua \
  FOCUS_LINT="src/mongodb/example.lua spec/unit/example_spec.lua"
```

Use `FOCUS_INTEGRATION`, `FOCUS_UNIFIED`, or `FOCUS_PYTHON` for the directly affected boundary. GitHub Actions runs the complete gates and compatibility matrix after each push.

See [`planning/README.md`](planning/README.md) for roadmap commands and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for implementation details and design decisions.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
