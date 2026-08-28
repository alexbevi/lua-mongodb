# Changelog

This file records changes that affect people who use the published driver. Internal test evidence, fixture inventories, and release automation belong in project records instead.

## [0.10.6] - 2026-08-28

Topology and connection logging complete the driver's standardized logging components.

### Added

- Topology lifecycle, server-description change, and heartbeat messages for standalone, replica-set, sharded, and load-balanced deployments.
- Connection-pool, connection, checkout, and check-in lifecycle messages, including load-balanced service identifiers where required.
- Non-default pool configuration fields for supported size, idle-time, connection-establishment, and wait-queue options.

### Conformance

- Closed the five logging requirements and 93 component cases: 89 pass, two old-server command branches are excluded, and two deprecated pool options are unsupported.

### Example

Enable topology and connection logs together to follow monitoring and pool activity:

```lua
local client = assert(mongodb.client("mongodb://localhost:27017/app", {
  logging = {
    levels = {
      connection = "debug",
      topology = "debug",
    },
  },
}))
```

## [0.10.5] - 2026-08-28

Server selection logging shows where an operation waited and which server it chose.

### Added

- `server_selection` started, waiting, succeeded, and failed messages across standalone, replica-set, sharded, and load-balanced deployments.
- Selector, topology, timing, selected-server, and failure fields in each message.
- One logical operation identifier across related server selection and command messages, including retries and bulk writes.

### Example

Enable command and server selection logs together to follow one operation through both components:

```lua
local client = assert(mongodb.client("mongodb://localhost:27017/app", {
  logging = {
    levels = {
      command = "debug",
      server_selection = "debug",
    },
  },
}))
```

## [0.10.4] - 2026-08-27

Command logging and monitoring expose command lifecycles without leaking sensitive fields.

### Added

- Command started, succeeded, and failed messages with stable request, operation, connection, and load-balanced service identifiers.
- Monitoring for generic commands, cursors, CRUD, collection and client bulk writes, unacknowledged writes, and write concern errors.
- Shared redaction for sensitive commands and server failures. Handshakes and monitor heartbeats stay outside command logs.

## [0.10.3] - 2026-08-27

This release introduced the configuration and event model used by component logging in later releases.

### Added

- Logging levels, destinations, environment defaults, programmatic overrides, and custom sinks.
- Immutable event documents with relaxed Extended JSON, redaction before Unicode-safe truncation, and sink-failure isolation.
- Logical operation identifiers that remain stable through retries and bulk sub-operations.

## [0.10.2] - 2026-08-26

GSSAPI authentication supports Kerberos credentials supplied by the operating system or, when supported by its library, a password.

### Added

- GSSAPI credential normalization, service-host canonicalization, and SASL authentication.
- A runtime provider that loads the operating system's GSSAPI library on Linux and macOS without a link-time Kerberos dependency.

Live GSSAPI authentication was verified with Lua 5.4 on Ubuntu 24.04. The macOS and Lua 5.5 package paths were not live authentication support claims for this release.

### Example

Omit the password to use the current Kerberos ticket cache:

```lua
local client = assert(mongodb.client(
  "mongodb://user%40EXAMPLE.COM@db.example.com/"
    .. "?authMechanism=GSSAPI"
    .. "&authMechanismProperties=SERVICE_NAME:mongodb"
))
```

## [0.10.1] - 2026-08-25

Maintenance release.

### Fixed

- Deprecated index `maxTimeMS` options no longer override a configured client-side operation timeout.
- ObjectId generation refreshes its five-byte process value after a fork while retaining the wrapping counter.

### Dependencies

- ObjectId process identity now uses the runtime-backed `getpid` 0.1.0-1 provider.

## [0.10.0] - 2026-08-25

Load-balanced deployments use service-aware pools and keep connections pinned when cursors or transactions require it.

### Added

- Static load-balanced topology and server selection with single-endpoint validation and per-service pool generations.
- Connection pinning for command cursors, sessions, and transactions, with cleanup after network failures, aborts, and cursor close.
- Transaction retry behavior that can unpin and select a fresh connection before another commit attempt.

### Example

Set `loadBalanced=true` for a load-balanced endpoint:

```lua
local client = assert(mongodb.client(
  "mongodb://lb.example.com/?loadBalanced=true"
))
```

## [0.9.0] - 2026-08-24

GridFS stores and retrieves files through bucket, upload-stream, and download-stream APIs.

### Added

- Configurable GridFS buckets, byte-string and readable-source uploads, required-index management, abort, and operation-wide timeouts.
- Download streams with bounded reads, seeking, filename revisions, and destination-copy methods that leave caller-owned streams open.
- Delete and rename operations by id or filename, cursor-based file discovery, and whole-bucket drop.

### Example

Upload a string and read it back by id:

```lua
local bucket = assert(client:database("app"):gridfs_bucket())
local file_id = assert(bucket:upload_from_stream(
  "greeting.txt",
  "Hello from GridFS!"
))
local download = assert(bucket:open_download_stream(file_id))

print(assert(download:read()))
assert(download:close())
```

## [0.8.0] - 2026-08-20

Wire compression is negotiated independently for each connection.

### Added

- Ordered `snappy`, `zlib`, and `zstd` compressor configuration, zlib levels from `-1` through `9`, and warnings for unavailable optional providers.
- OP_COMPRESSED request and response handling with structured errors for malformed messages.
- Uncompressed authentication, handshake, and user-management commands as required by the MongoDB compression specification.

Zlib is a required dependency. Snappy and Zstandard need their optional Lua providers.

### Example

List compressors in client preference order:

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/app"
    .. "?compressors=zstd,snappy,zlib"
    .. "&zlibCompressionLevel=6"
))
```

## [0.7.0] - 2026-08-19

Client bulk writes can modify several namespaces in one operation on MongoDB 8.0 or newer.

### Added

- Insert, update, replace, and delete models for client-level bulk writes.
- Ordered and unordered execution, summary and verbose results, partial results, and individual write and write concern errors.
- Batch splitting, sessions, transactions, retryable and unacknowledged writes, Stable API options, sharded transaction pinning, and client-side operation timeouts.

### Example

Use `mongodb.client_bulk` models with `client:bulk_write`:

```lua
local doc = mongodb.bson.document
local client_bulk = mongodb.client_bulk
local result = assert(client:bulk_write({
  client_bulk.insert_one(
    "app.users",
    doc({ { "name", "Ada" } })
  ),
  client_bulk.update_one(
    "app.accounts",
    doc({ { "owner", "Ada" } }),
    doc({ { "$set", doc({ { "active", true } }) } })
  ),
}))

print(result.inserted_count, result.modified_count)
```

## [0.6.0] - 2026-08-18

Legacy command and cursor APIs are available for applications that still depend on them.

### Added

- The deprecated collection `count` command with inherited concerns, read preference, retryable reads, and client-side operation timeouts.
- Legacy collection mapReduce with inline and output modes and its required single-attempt read behavior.
- Database aggregation cursors with read/write pipeline routing, retries, timeouts, and empty-batch continuation.
- Tailable and awaitData find cursors with nonblocking empty-batch polling, bounded waits, and runtime cancellation.

Prefer `count_documents`, aggregation pipelines, and ordinary cursors in new code.

## [0.5.0] - 2026-08-18

Change streams watch collection, database, or cluster changes on replica-set and sharded deployments.

### Added

- Collection, database, and cluster streams with pipeline options, blocking and nonblocking iteration, resume-token access, and one resume attempt after an eligible error.
- Operation timeouts, comments, expanded events, namespace types, disambiguated update paths, and pre-image and post-image events.
- Collection rename with inherited write concern and rename and invalidate events.

### Example

Read the next change for a collection:

```lua
local stream = assert(users:watch())
local event, err = stream:next()
assert(event, err)

print(event:get("operationType"))
assert(stream:close())
```

## [0.4.0] - 2026-08-17

Sharded deployment support arrived with snapshot sessions and Search index management.

### Added

- Snapshot sessions with server-version checks, transaction rejection, snapshot read concerns, and stable snapshot-time access.
- Create, list, update, and drop operations for standard and vector Search indexes.
- Sharded discovery, monitoring modes, `srvMaxHosts`, command execution through mongos, transaction pinning, and recovery-token forwarding.
- Pool clearing after authentication, application, and monitor failures, with optional interruption of checked-out connections.

### Example

Use one server timestamp for every read in a snapshot session:

```lua
local session = assert(client:start_session({ snapshot = true }))
local user = assert(users:find_one(
  mongodb.bson.document({}),
  { session = session }
))

print(session:get_snapshot_time())
assert(session:end_session())
```

## [0.3.0] - 2026-08-14

Authentication expanded beyond SCRAM to X.509, PLAIN, AWS, and OIDC mechanisms.

### Added

- SASL PLAIN and MONGODB-X509 authentication with credential-safe errors and sensitive-command redaction.
- MONGODB-AWS credential lookup through environment variables, web identity, ECS endpoints, and EC2 metadata.
- MONGODB-OIDC machine and human callbacks, allowed-host checks, access and refresh token caching, and built-in Kubernetes, Azure, and GCP providers.
- Cached-token speculative OIDC authentication and one same-connection reauthentication retry after server code 391.

### Example

Let MONGODB-AWS resolve workload credentials outside the URI:

```lua
local client = assert(mongodb.client(
  "mongodb://db.example.com/?authMechanism=MONGODB-AWS"
))
```

## [0.2.0] - 2026-08-13

DNS seedlist discovery supports `mongodb+srv` connection strings and periodic SRV polling.

### Added

- `srvServiceName`, `srvMaxHosts`, implicit TLS, and the allowed `authSource`, `replicaSet`, and `loadBalanced` TXT defaults.
- Coroutine-safe SRV and TXT resolution with UDP queries, TCP fallback for truncated replies, deadlines, and cancellation.
- Parent-domain validation, explicit-option precedence, randomized host limits, and topology updates at the DNS TTL with a 60-second minimum.

### Example

Use the SRV hostname published by a deployment:

```lua
local client = assert(mongodb.client(
  "mongodb+srv://db.example.com/app"
))
```

## [0.1.0] - 2026-08-09

Initial release.

### Added

- Pure-Lua BSON, Extended JSON, OP_MSG, SDAM, CMAP, server selection, CRUD, collection bulk writes, administration, sessions, retries, transactions, monitoring, and client-side operation timeouts.
- A coroutine-aware Copas runtime with LuaSocket networking, LuaSec TLS, and luaossl cryptography behind runtime adapters.
- Standalone and replica-set support for MongoDB Community Server 7.0, 8.0, and 8.2 with SCRAM and TLS profiles.
