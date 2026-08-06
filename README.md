# Lua MongoDB Driver

This repository is the planning and implementation workspace for a pure-Lua MongoDB driver. It is pre-alpha: the client API shown below remains a target while foundation modules are implemented incrementally.

The driver will implement BSON, the MongoDB wire protocol, topology and connection management, authentication, sessions, retry behavior, and a unified specification-test runner in Lua. It will not wrap `libmongoc`. Native Lua modules may be used only behind runtime adapters for TCP, TLS, and cryptography.

## Target API

```lua
local mongodb = require("mongodb")

local client, err = mongodb.client("mongodb://localhost:27017", {
  runtime = mongodb.runtime.copas(),
})

if not client then
  print(err.message)
  return
end

local query = mongodb.bson.document({ { "name", "Ada" } })
local document, find_err = client:database("app")
  :collection("users")
  :find_one(query)
```

The initial compatibility target is Lua 5.4 with 64-bit `lua_Integer`, Copas 4.11, LuaSocket, LuaSec, and MongoDB server 7.0 through 8.2. Operational failures return `nil, structured_error`; programmer misuse may raise a Lua error.

The implemented `mongodb.bson` foundation provides explicit ordered documents and arrays; immutable values for every BSON wire type; exact Decimal128 and numeric wrappers; strict UTF-8 validation; configurable size/depth bounds; and ordered canonical/relaxed Extended JSON. ObjectId generation takes a runtime so time and entropy stay portable. Explicit containers prevent Lua table iteration order from changing command bytes, while exact wrappers preserve numeric wire types and bit patterns.

`mongodb.config.uri.parse` implements the non-SRV connection-string syntax boundary. It parses ordered seed lists, bracketed IPv6 literals, encoded Unix socket paths, credentials, authentication databases, and ordered query pairs without rendering credentials in structured errors. `mongodb.config.options.normalize` applies the same type, range, and combination rules to those URI pairs and to idiomatic Lua option tables, with programmatic values taking precedence. The resulting immutable configuration includes pool and timeout settings, TLS policy, retry flags, read/write concerns, read preference, and Stable API version 1 fields.

Unsupported or invalid URI options are ignored with returned warnings as required by the connection-string specification; unsupported programmatic keys and invalid programmatic values return structured configuration errors. Advanced post-v1 settings such as compression, SRV, proxy, and load-balanced options are intentionally not accepted by the v1 programmatic configuration boundary.

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

The project requires Lua 5.4 with 64-bit `lua_Integer`, LuaRocks, Copas 4.11, Busted 2.3, and Luacheck 1.2. Install the rockspec's runtime and development dependencies, then run:

```sh
make test-unit
make test-integration
make test-unified
make lint
make check
```

Every target checks its prerequisites and explains how to select a missing tool through `LUA`, `LUAROCKS`, `BUSTED`, `LUACHECK`, or `PYTHON`. `make test-unit` includes every pinned BSON and Extended JSON corpus representation, all 98 non-SRV connection-string fixtures plus their option-warning semantics, and the deterministic unified runner core. `make test-unified` validates all 320 distinct JSON meta-fixtures against the pinned unified schema 1.28 with the pure-Lua validator; real fixture execution remains incremental. Integration tests begin with the command executor slice rather than being counted as passing coverage before then.

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
