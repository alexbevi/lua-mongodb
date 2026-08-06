# Lua MongoDB Driver

This repository is the planning and implementation workspace for a pure-Lua MongoDB driver. It is pre-alpha: the driver API shown below is a target, not yet an implemented package.

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

local document, find_err = client:database("app")
  :collection("users")
  :find_one({ name = "Ada" })
```

The initial compatibility target is Lua 5.4 with 64-bit `lua_Integer`, Copas 4.11, LuaSocket, LuaSec, and MongoDB server 7.0 through 8.2. Operational failures return `nil, structured_error`; programmer misuse may raise a Lua error.

## Bootstrap

After cloning this repository, initialize the pinned references:

```sh
git submodule update --init --recursive
python3 planning/update_plan.py check
python3 planning/update_plan.py next
```

The roadmap lives in [`planning/plan.json`](planning/plan.json). [`planning/current_state.json`](planning/current_state.json) is generated from it and the mutable progress ledger. Use the commands documented in [`planning/README.md`](planning/README.md); do not edit generated state directly.

Architecture decisions are maintained in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), while [`planning/reference_architecture.md`](planning/reference_architecture.md) maps PyMongo and the MongoDB specifications to the planned Lua components.

## Scope

The `production-core-v1` milestone covers standalone and replica-set CRUD, TLS and SCRAM, SDAM and CMAP, monitoring, sessions, retries, transactions, and client-side operation timeout. Advanced features such as change streams, GridFS, SRV, compression, sharded and load-balanced deployments, extra authentication mechanisms, and client bulk write remain post-v1. Client-side field-level/queryable encryption and GSSAPI require separate designs.

## License

Apache License 2.0. See [`LICENSE`](LICENSE).

