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

Clients accept `mongodb://` and `mongodb+srv://` URIs. URI query parameters or Lua options configure TLS, authentication, topology, pooling, retries, and timeouts. SCRAM is the default password mechanism; X.509, OIDC, AWS, GSSAPI, and SASL PLAIN are also supported. OCSP and SOCKS5 are not supported.

Collection handles provide CRUD, aggregation, bulk writes, indexes, search indexes, and change streams. Database handles run commands and create GridFS buckets. Clients create sessions and cluster-wide change streams. Transactions and change streams require a replica set or sharded deployment.

Operations return a value on success or `nil, err` on failure. The example uses `assert` to stay short. Close clients, cursors, sessions, and streams when they are no longer needed.

## Examples

The [examples](examples/README.md) include connection, CRUD, transactions, and two-window LÖVE Pong using change streams.

## Specification compatibility

> [!NOTE]
> 🟢 Complete · 🟡 Partial · 🔴 Not implemented · ⚪ Will not implement

<!-- BEGIN SPEC CONFORMANCE -->
| Driver layer | Specification suite | Status | Pass rate |
| --- | --- | --- | ---: |
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
| Connectivity | [Server discovery and monitoring](https://alexbevi.com/specifications/server-discovery-and-monitoring/server-discovery-and-monitoring.html) | 🟡 | 98.9% |
| Connectivity | [Connection monitoring and pooling](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🟢 | 100.0% |
| Connectivity | [Load balancer support](https://alexbevi.com/specifications/load-balancers/load-balancers.html) | 🟢 | 100.0% |
| Authentication | [Authentication options and additional mechanisms](https://alexbevi.com/specifications/auth/auth.html) | 🟢 | 100.0% |
| Availability | [Server selection](https://alexbevi.com/specifications/server-selection/server-selection.html) | 🟢 | 100.0% |
| Availability | [Max staleness](https://alexbevi.com/specifications/max-staleness/max-staleness.html) | 🟢 | 100.0% |
| Availability | [Periodic SRV polling](https://alexbevi.com/specifications/polling-srv-records-for-mongos-discovery/polling-srv-records-for-mongos-discovery.html) | 🟢 | 100.0% |
| Resilience | [Retryable reads](https://alexbevi.com/specifications/retryable-reads/retryable-reads.html) | 🟢 | 100.0% |
| Resilience | [Retryable writes](https://alexbevi.com/specifications/retryable-writes/retryable-writes.html) | 🟢 | 100.0% |
| Resilience | [Client-side operations timeout](https://alexbevi.com/specifications/client-side-operations-timeout/client-side-operations-timeout.html) | 🟡 | 99.4% |
| Resilience | [Sessions](https://alexbevi.com/specifications/sessions/driver-sessions.html) | 🟢 | 100.0% |
| Resilience | [Causal consistency](https://alexbevi.com/specifications/causal-consistency/causal-consistency.html) | 🟢 | 100.0% |
| Resilience | [Transactions](https://alexbevi.com/specifications/transactions/transactions.html) | 🟡 | 96.5% |
| Resilience | [Convenient transactions API](https://alexbevi.com/specifications/transactions-convenient-api/transactions-convenient-api.html) | 🟢 | 100.0% |
| Programmability | [CRUD](https://alexbevi.com/specifications/crud/crud.html) | 🟢 | 100.0% |
| Programmability | [Collection management](https://alexbevi.com/specifications/enumerate-collections/enumerate-collections.html) | 🟢 | 100.0% |
| Programmability | [Index management](https://alexbevi.com/specifications/index-management/index-management.html) | 🟢 | 100.0% |
| Programmability | [Read/write concern](https://alexbevi.com/specifications/read-write-concern/read-write-concern.html) | 🟢 | 100.0% |
| Programmability | [Change streams](https://alexbevi.com/specifications/change-streams/change-streams.html) | 🟢 | 100.0% |
| Programmability | [GridFS](https://alexbevi.com/specifications/gridfs/gridfs-spec.html) | 🟢 | 100.0% |
| Programmability | [Stable API](https://alexbevi.com/specifications/versioned-api/versioned-api.html) | 🟢 | 100.0% |
| Programmability | [Client-side encryption](https://alexbevi.com/specifications/client-side-encryption/client-side-encryption.html) | 🔴 | 0.0% |
| Observability | [Command logging and monitoring](https://alexbevi.com/specifications/command-logging-and-monitoring/command-logging-and-monitoring.html) | 🟢 | 100.0% |
| Observability | [Standardized logging](https://alexbevi.com/specifications/logging/logging.html) | 🟢 | 100.0% |
| Observability | [Client backpressure](https://alexbevi.com/specifications/connection-monitoring-and-pooling/connection-monitoring-and-pooling.html) | 🔴 | 0.0% |
| Observability | [OpenTelemetry](https://alexbevi.com/specifications/open-telemetry/open-telemetry.html) | 🔴 | 0.0% |
| Testability | [Unified test format](https://alexbevi.com/specifications/unified-test-format/unified-test-format.html) | 🟢 | 100.0% |
|  | **Total** |  | **83.0%** |
<!-- END SPEC CONFORMANCE -->

## License

Apache License 2.0. See [`LICENSE`](LICENSE).
