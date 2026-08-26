# API stability

The supported API is smaller than the set of Lua modules installed by the rock. The
machine-readable source of truth is
[`spec/module-classification.json`](../spec/module-classification.json); it assigns every
packaged module and every export from `require("mongodb")` to one stability tier.

## Stability tiers

| Tier | Contract |
|---|---|
| Public | Intended for application code and covered by package-install tests. |
| Advanced extension | Supported for custom runtime adapters and providers, but requires knowledge of the runtime contract. |
| Compatibility only | Retained for existing consumers; new code should use the public or advanced surface instead. |
| Internal | Installed because the driver is split into Lua modules. Packaging does not make these modules supported entry points. |
| Test only | Repository test support that is not included in the rock. |

The public and advanced-extension tiers are the supported API. Internal modules may change
without notice, including modules below `mongodb.auth`, `mongodb.command`, `mongodb.config`,
`mongodb.discovery`, `mongodb.network`, and `mongodb.wire`. Code should not infer support from
whether `require` can load a packaged module.

## Supported module entry points

Public modules:

| Module | Purpose |
|---|---|
| `mongodb` | Driver façade and application entry point. |
| `mongodb.bson` | BSON values and binary codec. |
| `mongodb.bson.json` | JSON and Extended JSON conversion. |
| `mongodb.bulk` | Collection bulk-write models. |
| `mongodb.client_bulk` | Client bulk-write models. |
| `mongodb.error` | Structured error categories and helpers. |

Advanced extension modules:

| Module | Purpose |
|---|---|
| `mongodb.runtime` | Runtime validation, deadlines, cancellation helpers, and the default adapter constructor. |
| `mongodb.runtime.contract` | Dependency-free runtime contract helpers. |
| `mongodb.runtime.copas` | Default Copas runtime construction and scheduler entry point. |
| `mongodb.runtime.fake` | Deterministic runtime for adapter and integration testing. |
| `mongodb.runtime.luasec` | LuaSec TLS provider. |
| `mongodb.runtime.snappy` | Optional Snappy compression provider. |
| `mongodb.runtime.zlib` | zlib compression provider. |
| `mongodb.runtime.zstandard` | Optional Zstandard compression provider. |

`mongodb.runtime.openssl` is a compatibility-only module. Its historical name remains
available for runtime injection even though its implementation no longer depends on luaossl.

## Conventions

Signatures use brackets for optional arguments and `...` for multiple Lua values. A union such
as `client | nil, err` means that success returns the value and failure returns two values. An
`err` result is always a structured error described below.

Operational failures return `nil, err`. Programmer errors raise: wrong Lua value types, unknown
options, and malformed extension objects are caller bugs rather than server or network outcomes.
A method can also raise when an internal invariant is violated. Individual entries call out any
narrower lifecycle behavior.

## `mongodb` façade

`require("mongodb")` is the preferred entry point. Its public exports are `_VERSION`, `bson`,
`bulk`, `client`, `client_bulk`, `error`, `gridfs_bucket`, `index_model`, and `run`. The
`runtime` export is advanced-extension API.

| Export | Tier | Signature or value |
|---|---|---|
| `_VERSION` | Public | `mongodb._VERSION -> string` |
| `bson` | Public | `mongodb.bson -> mongodb.bson module` |
| `bulk` | Public | `mongodb.bulk -> mongodb.bulk module` |
| `client` | Public | Constructor described below. |
| `client_bulk` | Public | `mongodb.client_bulk -> mongodb.client_bulk module` |
| `error` | Public | `mongodb.error -> mongodb.error module` |
| `gridfs_bucket` | Public | Constructor described below. |
| `index_model` | Public | Constructor described below. |
| `run` | Public | Scheduler entry point described below. |
| `runtime` | Advanced extension | `mongodb.runtime -> mongodb.runtime module` |
| `pool` | Compatibility only | `mongodb.pool -> pool module` |
| `sdam` | Compatibility only | `mongodb.sdam -> SDAM module` |
| `selection` | Compatibility only | `mongodb.selection -> server-selection module` |
| `topology` | Compatibility only | `mongodb.topology -> topology module` |

The compatibility-only exports remain present for existing consumers. New application code
should use client, database, collection, and runtime APIs. Their implementation modules are
internal, so the corresponding direct `require` paths are not supported entry points.

### `mongodb.client`

`mongodb.client(uri [, options]) -> client | nil, err`

`uri` is a `mongodb://` or `mongodb+srv://` string. `options`, when present, is a table using
Lua `snake_case` names; URI query parameters retain MongoDB URI spelling. The constructor
returns a client handle, or `nil` and a configuration, DNS, topology, authentication, or network
error. A non-string URI, a non-table options value, an unknown programmatic option, or an
invalid caller-supplied runtime raises. Client options and handle methods are specified in the
[README usage guide](../README.md#getting-started).

### `mongodb.gridfs_bucket`

`mongodb.gridfs_bucket(database [, options]) -> bucket | nil, err`

The first argument must be a database handle from this driver. Recognized options are
`bucket_name`, `chunk_size_bytes`, `disable_md5`, `read_concern`, `read_preference`,
`timeout_ms`, and `write_concern`. Invalid option value combinations return a configuration
error; an invalid database value, non-table options value, or unknown option raises. GridFS
methods and ownership rules remain in the [GridFS guide](../README.md#gridfs).

### `mongodb.index_model`

`mongodb.index_model(keys [, options]) -> index_model`

`keys` must be a non-empty ordered BSON document with valid index directions. The constructor
returns an immutable model whose `name` is explicit or deterministically generated. Invalid
keys, option names, or option values are programmer errors and raise. Index options and model
properties remain in the [index guide](../README.md#index-management).

### `mongodb.run`

`mongodb.run(callback, ...) -> ...`

This helper owns the Copas loop for the duration of `callback`, passes through every additional
argument, and returns every value returned by the callback. It must be called outside an active
Copas loop. A non-function callback, an already active loop, premature loop exit, or an error
raised by the callback raises to the caller. Applications that already own a Copas loop call
`mongodb.client` inside that loop instead.

## Structured errors

`mongodb.error` is available both as `require("mongodb.error")` and as `mongodb.error`. Error
values are immutable records, not an exception hierarchy. The public category constants are
`AUTHENTICATION`, `BSON`, `CANCELLED`, `CLIENT`, `CONFIGURATION`, `INTERNAL`, `NETWORK`,
`POOL`, `PROTOCOL`, `SERVER`, `SERVER_SELECTION`, `TIMEOUT`, `TOPOLOGY`, `TRANSACTION`, and
`WRITE`, collected in the immutable `mongodb.error.CATEGORY` table.

| Constant | Value | Constant | Value |
|---|---|---|---|
| `AUTHENTICATION` | `authentication` | `BSON` | `bson` |
| `CANCELLED` | `cancelled` | `CLIENT` | `client` |
| `CONFIGURATION` | `configuration` | `INTERNAL` | `internal` |
| `NETWORK` | `network` | `POOL` | `pool` |
| `PROTOCOL` | `protocol` | `SERVER` | `server` |
| `SERVER_SELECTION` | `server_selection` | `TIMEOUT` | `timeout` |
| `TOPOLOGY` | `topology` | `TRANSACTION` | `transaction` |
| `WRITE` | `write` | | |

### Construction and fields

`mongodb.error.new(options) -> err`

`options` must contain a known `category` value and a non-empty `message`. It may contain only
the fields below. Invalid constructor input is a programmer error and raises.

| Field | Contract |
|---|---|
| `category` | Required category string from `mongodb.error.CATEGORY`. |
| `message` | Required non-empty diagnostic string. |
| `code` | Optional MongoDB integer error code. |
| `code_name` | Optional non-empty MongoDB code name. |
| `labels` | Read-only, insertion-ordered array of unique non-empty strings; defaults to empty. |
| `cause` | Optional structured error forming a causal chain. |
| `server` | Optional non-empty server-address string. |
| `topology` | Optional non-empty topology description string. |
| `timeout` | Boolean; true for the timeout category, an explicit timeout, or a timeout cause. |
| `retryable` | Boolean copied from the constructor; defaults to false. |
| `details` | Optional recursively read-only table for machine-readable context. |

Assigning to an error, its labels, its details, or the category table raises. `tostring(err)`
returns a stable diagnostic containing category, message, optional code and code name, and
optional server. It deliberately omits `details` and the causal chain so arbitrary server data
and secrets are not rendered.

### Predicates and label transforms

- `mongodb.error.is(value [, category]) -> boolean` returns false for non-error values; with a
  category it also requires an exact category match.
- `mongodb.error.has_label(value, label) -> boolean` returns false for non-error values and tests
  exact label membership for structured errors.
- `mongodb.error.with_label(err, label) -> err` returns the original value when the label is
  already present, otherwise a new immutable error.
- `mongodb.error.without_label(err, label) -> err` returns the original value when the label is
  absent, otherwise a new immutable error.
- `err:has_label(label) -> boolean` is the instance form of the label predicate.
- `err:is_category(category) -> boolean` tests the exact category.
- `err:is_timeout() -> boolean` returns the derived timeout flag.
- `err:is_retryable() -> boolean` returns the retryable flag.

The transform functions require a structured error and a non-empty string label; misuse raises.
Driver operational APIs return these values as `nil, err`. They do not throw structured errors
for ordinary server, network, timeout, cancellation, or configuration outcomes.

## Runtime API

The runtime boundary keeps clocks, scheduling, cancellation, files, environment, networking,
TLS, entropy, and cryptography outside the driver core. A client uses the `runtime` supplied in
its options or constructs the default Copas runtime. A caller-supplied runtime remains owned by
the caller and must outlive every client using it; closing a client closes its MongoDB resources
but does not close or stop the runtime. `mongodb.run` owns the Copas loop it creates, while an
application with an existing loop owns that loop itself.

### Runtime façade and contract helpers

The advanced `mongodb.runtime` façade has these signatures:

- `mongodb.runtime.copas([options]) -> runtime` constructs and validates the default adapter.
- `mongodb.runtime.validate(runtime) -> runtime` returns the same table after structural
  validation; a missing capability or malformed optional provider raises.
- `mongodb.runtime.required_capabilities() -> paths` returns a new array containing the 24
  required dotted capability names.
- `mongodb.runtime.deadline_after(runtime, duration) -> deadline` adds a finite non-negative
  duration to the adapter's monotonic clock.
- `mongodb.runtime.remaining(runtime, deadline) -> seconds | nil` returns a value clamped to
  zero, or nil when the deadline is nil.
- `mongodb.runtime.check(runtime [, deadline [, cancellation]]) -> true | nil, err` returns a
  cancellation error first, a timeout error when the absolute deadline has expired, or true.
- `mongodb.runtime.cancelled_error([reason]) -> err` constructs a cancellation-category error.
- `mongodb.runtime.timeout_error() -> err` constructs a timeout-category error.

Durations, deadlines, cancellation values, and adapter shapes are programmer inputs; invalid
ones raise. Expired deadlines and observed cancellation are operational failures and return
`nil, err`.

`require("mongodb.runtime.contract")` exposes the same `validate`, `required_capabilities`,
`deadline_after`, `remaining`, `check`, `cancelled_error`, and `timeout_error` functions under
the `mongodb.runtime.contract.*` names. Adapter implementations can depend on this module
without importing the default Copas constructor.

### Required adapter capabilities

All required functions are called with colon syntax. A deadline is an absolute value from the
same runtime's monotonic clock; nil means no deadline. Operational provider failures return
`nil, err`, while malformed arguments or provider results raise.

| Capability | Required signature and result |
|---|---|
| `clock.now` | `runtime.clock:now() -> seconds`; finite, non-negative, and monotonic. |
| `clock.sleep` | `runtime.clock:sleep(duration [, cancellation]) -> true`; cancellation returns `nil, err`. |
| `clock.wall_time` | `runtime.clock:wall_time() -> unix_seconds`; finite and non-negative. |
| `cancellation.new` | `runtime.cancellation:new() -> cancellation`. |
| `task.spawn` | `runtime.task:spawn(callback, ...) -> task`. |
| `task.await` | `runtime.task:await(task) -> ...`; cancellation returns `nil, err`, and callback failures raise. |
| `task.cancel` | `runtime.task:cancel(task [, reason]) -> boolean`. |
| `lock.new` | `runtime.lock:new() -> lock`. |
| `process.identity` | `runtime.process:identity() -> positive_integer`; read dynamically. |
| `environment.get` | `runtime.environment:get(name) -> string`; missing values return nil. |
| `file.read` | `runtime.file:read(path [, options]) -> string`; operational failure returns `nil, err`. |
| `http.request` | `runtime.http:request(request [, deadline [, cancellation]]) -> response`; operational failure returns `nil, err`. |
| `dns.resolve_srv` | `runtime.dns:resolve_srv(name [, deadline [, cancellation]]) -> records`; operational failure returns `nil, err`. |
| `dns.resolve_txt` | `runtime.dns:resolve_txt(name [, deadline [, cancellation]]) -> records`; operational failure returns `nil, err`. |
| `socket.connect` | `runtime.socket:connect(host, port, options [, deadline [, cancellation]]) -> socket`; operational failure returns `nil, err`. |
| `tls.wrap` | `runtime.tls:wrap(socket, options [, deadline [, cancellation]]) -> socket`; operational failure returns `nil, err`. |
| `entropy.bytes` | `runtime.entropy:bytes(count) -> string`; success has exactly `count` bytes, and operational failure returns `nil, err`. |
| `crypto.md5` | `runtime.crypto:md5(data) -> bytes`; operational failure returns `nil, err`. |
| `crypto.sha1` | `runtime.crypto:sha1(data) -> bytes`; operational failure returns `nil, err`. |
| `crypto.sha256` | `runtime.crypto:sha256(data) -> bytes`; operational failure returns `nil, err`. |
| `crypto.hmac_sha1` | `runtime.crypto:hmac_sha1(key, data) -> bytes`; operational failure returns `nil, err`. |
| `crypto.hmac_sha256` | `runtime.crypto:hmac_sha256(key, data) -> bytes`; operational failure returns `nil, err`. |
| `crypto.pbkdf2_sha1` | `runtime.crypto:pbkdf2_sha1(password, salt, iterations, length) -> bytes`; operational failure returns `nil, err`. |
| `crypto.pbkdf2_sha256` | `runtime.crypto:pbkdf2_sha256(password, salt, iterations, length) -> bytes`; operational failure returns `nil, err`. |

A cancellation value supplies `cancel([reason]) -> boolean`, `is_cancelled() -> boolean`,
`reason() -> string | nil`, and `on_cancel(callback) -> unsubscribe`. A task is owned by the
runtime that created it. A lock supplies
`acquire([deadline [, cancellation]]) -> true | nil, err`, `release() -> true`, and
`is_locked() -> boolean`.

A connected socket supplies
`read_some(max_bytes [, deadline [, cancellation]]) -> string | nil, err`,
`write_some(data [, deadline [, cancellation]]) -> count | nil, err`, `close() -> boolean`, and
`is_closed() -> boolean`. TLS returns an object with the same socket contract.
SRV results are arrays of `{ target, port, priority, weight, ttl }` records; TXT results are
arrays of `{ strings, ttl }` records. An HTTP request has `url` plus optional `method`, `body`,
`headers`, and `max_response_bytes`; a response has integer `status`, string `body`, and a
normalized `headers` table. File-read options are `deadline`, `cancellation`, and a positive
integer `max_bytes`.

`runtime.metadata` is optional and contains handshake facts rather than active providers. A
runtime may also expose `compression`, keyed by compressor name. Each compression provider has
a matching `name`, a unique integer `compressor_id` from 1 through 255, and `compress` and
`decompress` functions. `mongodb.runtime.validate` checks the required function paths, optional
metadata type, and compression-provider shape; adapter authors remain responsible for the
method semantics above.

### Built-in runtime modules

- `mongodb.runtime.copas.new([options]) -> runtime` constructs the default adapter. The same
  constructor is exposed as `mongodb.runtime.copas([options])`. It accepts Copas 4.11 or 4.12,
  optional capability/provider overrides, metadata, clock/process/environment hooks, DNS
  settings, and a positive lock poll interval. Unknown options and malformed providers raise.
- `mongodb.runtime.copas.run(callback, ...) -> ...` is the implementation behind `mongodb.run`
  and has the same loop ownership and error behavior.
- `mongodb.runtime.fake.new([options]) -> runtime` constructs a deterministic adapter for tests.
  Options can seed monotonic and wall time, process identity, entropy, environment values,
  bounded file values, metadata, and compression providers. Its queue and clock-control methods
  are test instrumentation, not requirements for custom adapters.
- `mongodb.runtime.luasec.new(runtime [, options]) -> tls_provider` returns a provider whose
  `wrap(socket, tls_options [, deadline [, cancellation]])` operation returns a compatible
  socket or `nil, err`. Constructor options can inject LuaSec and the socket adapter or select
  default CA paths. TLS policy validation errors are structured configuration failures;
  malformed constructor input raises.
- `mongodb.runtime.snappy.new(binding) -> compression_provider` and
  `mongodb.runtime.snappy.load([loader]) -> compression_provider | nil` adapt a binding with
  `compress` and `decompress` functions. `load` returns nil when the optional binding is absent
  or malformed.
- `mongodb.runtime.zlib.new(binding) -> compression_provider` and
  `mongodb.runtime.zlib.load([loader]) -> compression_provider | nil` adapt `deflate` and
  `inflate`; `provider:compress(data, level)` accepts levels -1 through 9.
- `mongodb.runtime.zstandard.new(binding) -> compression_provider` and
  `mongodb.runtime.zstandard.load([loader]) -> compression_provider | nil` adapt a binding with
  `compress` and `decompress` functions. `load` returns nil when the optional binding is absent
  or malformed.

Compression and TLS operations return `nil, err` for operational provider failures. Invalid
bindings, loaders, input types, or zlib levels are programmer errors and raise.

The Copas constructor recognizes only these options:

| Option | Meaning |
|---|---|
| `copas` | Injected Copas module, required to report a supported 4.11.x or 4.12.x version. |
| `compression` | Compression-provider map; an empty table disables the discovered defaults. |
| `crypto`, `entropy`, `dns`, `file`, `http`, `socket`, `tls` | Complete capability overrides. |
| `dns_nameservers` | Adapter-local nameserver list for the default DNS provider. |
| `dns_query_timeout` | Positive per-nameserver DNS query bound in seconds. |
| `getpid`, `getenv`, `gettime`, `wall_time` | Function overrides for process, environment, monotonic-clock, and wall-clock access. |
| `lock_poll_interval` | Positive cancellation polling interval in seconds; defaults to 0.05. |
| `metadata` | Handshake fact table exposed as `runtime.metadata`. |

The fake constructor accepts `now`, `wall_time`, `process_identity`, `entropy`, `environment`,
`files`, `metadata`, and `compression` seeds. The LuaSec constructor accepts `default_ca_file`,
`default_ca_path`, `socket_adapter`, and `ssl`. These constructor values are copied or retained
according to their provider role; applications must not mutate a live runtime's capabilities.

## Pre-1.0 change policy

The project remains on the `0.x` release line. Patch releases preserve the public and advanced
extension contracts. If a minor release must make an incompatible change to either supported
tier, the release notes and `CHANGELOG.md` will identify it as a breaking change and describe
the migration. Compatibility-only exports may be deprecated or removed in a minor release with
the same notice. Internal and test-only modules carry no compatibility promise.
