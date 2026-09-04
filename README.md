# MongoDB Lua driver

A coroutine-aware MongoDB driver written in Lua without binding or wrapping `libmongoc`. It supports Lua 5.4 and Lua 5.5, standalone servers, [replica sets](https://www.mongodb.com/docs/manual/replication/), [sharded clusters](https://www.mongodb.com/docs/manual/sharding/), and load-balanced deployments.

## Dependencies

- Lua 5.4 or Lua 5.5 with a 64-bit `lua_Integer`.
- [Copas](https://lunarmodules.github.io/copas/) 4.11.x or 4.12.x.
- [LuaSocket](https://lunarmodules.github.io/luasocket/) 3.1 or later, before 4.0.
- [LuaSec](https://github.com/lunarmodules/luasec) 1.3.x.
- `getpid` 0.1.0, `sha1` 0.5, `md5` 1.3, `lua-cryptorandom` 0.0.6, and `lua-zlib` 1.4 or compatible releases.
- Optional Snappy and Zstandard compression use `lua-csnappy` 0.1.5 and `lua-zstd` 0.2 or compatible releases. `lua-zstd` also needs the Zstandard library and development headers.
- OpenSSL libraries and development headers required by the TLS dependency and by `lua-cryptorandom` on supported Unix-like platforms.

Install either optional compression provider separately:

```sh
luarocks install lua-csnappy
luarocks install lua-zstd
```

## Building and installing

```sh
luarocks install mongodb
```

From a source checkout:

```sh
luarocks make
```

## Getting started

MongoDB operations run inside a Copas loop. `mongodb.run` owns that loop for a standalone program. Applications with an existing Copas loop can create clients inside it.

```lua
local mongodb = require("mongodb")
local doc = mongodb.bson.document

mongodb.run(function()
  local client = assert(mongodb.client("mongodb://localhost:27017/app"))
  local users = client:database():collection("users")

  local inserted = assert(users:insert_one(doc({ { "name", "Ada" } })))
  local user = assert(users:find_one(inserted.inserted_id))

  print(user:get("name"))
  assert(client:close())
end)
```

Operations return a value on success or `nil, err` on failure. The example uses `assert` to stay short. Close clients, cursors, sessions, and streams when they are no longer needed.

## Examples

Additional [examples](examples/README.md) include connection, CRUD, transactions, and two-window LÖVE Pong using change streams.

### Transactions

```lua
--[[
Transfer funds in a transaction using SCRAM and zlib compression.
This requires a replica set or sharded deployment.
]]
local mongodb = require("mongodb")
local doc = mongodb.bson.document

mongodb.run(function()
  local client = assert(mongodb.client(
    "mongodb://app-user:secret@db.example.com/bank"
      .. "?authSource=admin&replicaSet=rs0&compressors=zlib"
  ))
  local accounts = client:database():collection("accounts")
  local session = assert(client:start_session())

  assert(session:with_transaction(function(active_session)
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
  end))

  assert(session:end_session())
  assert(client:close())
end)
```

### Client bulk writes

```lua
--[[
Write to two namespaces using X.509 authentication and Zstandard compression.
Client bulk writes require MongoDB 8.0 or newer.
]]
local mongodb = require("mongodb")
local bulk = mongodb.client_bulk
local doc = mongodb.bson.document

mongodb.run(function()
  local client = assert(mongodb.client(
    "mongodb://db.example.com/?authMechanism=MONGODB-X509"
      .. "&tls=true&compressors=zstd",
    {
      tls_ca_file = "/path/to/ca.pem",
      tls_certificate_key_file = "/path/to/client.pem",
    }
  ))

  local result = assert(client:bulk_write({
    bulk.insert_one("app.users", doc({ { "name", "Ada" } })),
    bulk.update_one(
      "audit.events",
      doc({ { "kind", "login" } }),
      doc({ { "$set", doc({ { "reviewed", true } }) } })
    ),
  }))

  print(result.inserted_count, result.modified_count)
  assert(client:close())
end)
```

### Change streams

```lua
--[[
Watch a collection using Kubernetes OIDC authentication.
Change streams require a replica set or sharded deployment.
]]
local mongodb = require("mongodb")

mongodb.run(function()
  local client = assert(mongodb.client(
    "mongodb://db.example.com/app?authMechanism=MONGODB-OIDC"
      .. "&authMechanismProperties=ENVIRONMENT:k8s&tls=true"
  ))
  local users = client:database():collection("users")
  local stream = assert(users:watch())
  local change = assert(stream:next())

  print(change:get("operationType"))
  assert(stream:close())
  assert(client:close())
end)
```

### GridFS

```lua
--[[
Upload and download a small file using MONGODB-AWS authentication.
Credentials come from the AWS credential provider chain.
]]
local mongodb = require("mongodb")

mongodb.run(function()
  local client = assert(mongodb.client(
    "mongodb+srv://cluster.example.com/app?authMechanism=MONGODB-AWS"
  ))
  local bucket = assert(client:database():gridfs_bucket())
  local file_id = assert(bucket:upload_from_stream(
    "greeting.txt",
    "Hello from GridFS!"
  ))
  local download = assert(bucket:open_download_stream(file_id))

  print(assert(download:read()))
  assert(download:close())
  assert(client:close())
end)
```

## MongoDB drivers specification compatibility

The [MongoDB driver specifications](https://alexbevi.com/specifications/) cover behavior shared across MongoDB drivers.

> [!NOTE]
> 🟢 Complete · 🟡 Partial · 🔴 Not implemented · ⚪ Will not implement

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status | Pass rate |
| --- | --- | --- | ---: |
| Serialization | [BSON corpus](https://alexbevi.com/specifications/bson-corpus/bson-corpus.html) | 🟢 | 100.0% |
| Serialization | [BSON binary vector](https://alexbevi.com/specifications/bson-binary-vector/bson-binary-vector.html) | 🟢 | 100.0% |
| Communication | [Connection string](https://alexbevi.com/specifications/connection-string/connection-string-spec.html) | 🟢 | 100.0% |
| Communication | [URI options](https://alexbevi.com/specifications/uri-options/uri-options.html) | 🟢 | 100.0% **†** |
| Communication | [Handshake metadata propagation](https://alexbevi.com/specifications/mongodb-handshake/handshake.html) | 🟢 | 100.0% |
| Communication | [Initial DNS seedlist discovery](https://alexbevi.com/specifications/initial-dns-seedlist-discovery/initial-dns-seedlist-discovery.html) | 🟢 | 100.0% |
| Communication | [OCSP support](https://alexbevi.com/specifications/ocsp-support/ocsp-support.html) | ⚪ | N/A |
| Communication | [Wire compression](https://alexbevi.com/specifications/compression/OP_COMPRESSED.html) | 🟢 | 100.0% |
| Communication | [SOCKS5 proxy support](https://alexbevi.com/specifications/socks5-support/socks5.html) | ⚪ | N/A |
| Communication | [Command execution](https://alexbevi.com/specifications/run-command/run-command.html) | 🟢 | 100.0% |
| Connectivity | [Server discovery and monitoring](https://alexbevi.com/specifications/server-discovery-and-monitoring/server-discovery-and-monitoring.html) | 🟢 | 100.0% **†** |
| Connectivity | [Connection monitoring and pooling](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🟢 | 100.0% **†** |
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
| Resilience | [Transactions](https://alexbevi.com/specifications/transactions/transactions.html) | 🟢 | 100.0% **†** |
| Resilience | [Convenient transactions API](https://alexbevi.com/specifications/transactions-convenient-api/transactions-convenient-api.html) | 🟢 | 100.0% |
| Programmability | [CRUD](https://alexbevi.com/specifications/crud/crud.html) | 🟢 | 100.0% **†** |
| Programmability | [Collection management](https://alexbevi.com/specifications/enumerate-collections/enumerate-collections.html) | 🟢 | 100.0% |
| Programmability | [Index management](https://alexbevi.com/specifications/index-management/index-management.html) | 🟢 | 100.0% |
| Programmability | [Read/write concern](https://alexbevi.com/specifications/read-write-concern/read-write-concern.html) | 🟢 | 100.0% |
| Programmability | [Change streams](https://alexbevi.com/specifications/change-streams/change-streams.html) | 🟢 | 100.0% **†** |
| Programmability | [GridFS](https://alexbevi.com/specifications/gridfs/gridfs-spec.html) | 🟢 | 100.0% |
| Programmability | [Stable API](https://alexbevi.com/specifications/versioned-api/versioned-api.html) | 🟢 | 100.0% |
| Programmability | [Client-side encryption](https://alexbevi.com/specifications/client-side-encryption/client-side-encryption.html) | ⚪ | N/A **†** |
| Observability | [Command logging and monitoring](https://alexbevi.com/specifications/command-logging-and-monitoring/command-logging-and-monitoring.html) | 🟢 | 100.0% **†** |
| Observability | [Standardized logging](https://alexbevi.com/specifications/logging/logging.html) | 🟢 | 100.0% |
| Observability | [Client backpressure](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | ⚪ | N/A |
| Observability | [OpenTelemetry](https://alexbevi.com/specifications/open-telemetry/open-telemetry.html) | ⚪ | N/A |
| Testability | [Atlas SFP testing](https://alexbevi.com/specifications/atlas-sfp-testing/atlas-sfp-testing.html) | ⚪ | N/A |
| Testability | [Unified test format](https://alexbevi.com/specifications/unified-test-format/unified-test-format.html) | 🟢 | 100.0% |
|  | **Total** |  | **99.9%** **†** |

> [!IMPORTANT]
> **† Fixtures excluded from scoring.**
>
> Percentages marked **†** skip 106 upstream fixtures because their `runOnRequirements` restrict them to MongoDB versions older than the supported 7.0 floor. The affected suites are CRUD (74), Change streams (19), Command logging and monitoring (4), Retryable writes (3), Sessions (3), Server discovery and monitoring (2), and Client-side encryption (1). These fixtures remain classified in the conformance ledger but do not count toward the marked suite percentages or the total.
>
> The ledger also omits 3 explicit superseded or upstream-skipped fixtures from Authentication options and additional mechanisms (2), Load balancer support (1).
>
> The ledger excludes 37 terminal unsupported fixtures from scoring in URI options (21), Transactions (9), Server discovery and monitoring (5), Connection monitoring and pooling (2).
<!-- END SPEC CONFORMANCE -->

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
