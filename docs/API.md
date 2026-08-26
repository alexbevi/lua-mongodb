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

## BSON API

`mongodb.bson` is available through `require("mongodb.bson")` and as `mongodb.bson`. The
module represents documents and arrays explicitly so BSON field order, duplicate keys, exact
numeric wire types, binary subtypes, and null remain distinguishable in Lua. BSON value objects
are immutable. Constructors copy their sequence inputs, and the collection accessors that
return tables return fresh copies.

### Ordered documents and arrays

`bson.document(entries) -> document`

`entries` is a dense Lua array of two-element `{ key, value }` arrays. Keys must be strings,
cannot contain NUL, and values cannot be nil; use `bson.null` for BSON null. A document
preserves insertion order and duplicate keys. It has these methods:

- `document:get(key) -> value | nil` returns the value from the last matching entry.
- `document:get_at(index) -> key, value | nil` returns the key and value at a one-based
  positive integer index, or nil when no entry exists.
- `document:keys() -> keys` returns a new array of keys in stored order, including duplicates.
- `document:entries() -> entries` returns a new array of key-value pairs in stored order.
- `document:iter() -> iterator` returns an iterator yielding `key, value` in stored order.

`#document` is the number of entries, not the number of distinct keys.

`bson.array(values) -> array`

`values` is a dense Lua array. It cannot contain nil; use `bson.null`. A BSON array has these
methods:

- `array:get(index) -> value | nil` returns the value at a one-based positive integer index.
- `array:values() -> values` returns a new dense Lua array.
- `array:iter() -> iterator` returns an iterator yielding `index, value` in order.

`#array` is the number of values. Plain Lua tables are never inferred as documents or arrays
during encoding; applications must use these constructors to remove that ambiguity.

### Binary and vector values

`bson.binary(data [, subtype]) -> binary`

`data` is an arbitrary byte string. `subtype` is an integer from 0 through 255 and defaults to
`bson.BINARY_SUBTYPE.GENERIC`. The result exposes read-only `data` and `subtype` fields and
compares by both fields.

The immutable `bson.BINARY_SUBTYPE` table defines the standard numeric subtype values:

| Name | Value | Name | Value |
|---|---:|---|---:|
| `GENERIC` | 0 | `FUNCTION` | 1 |
| `OLD_BINARY` | 2 | `OLD_UUID` | 3 |
| `UUID` | 4 | `MD5` | 5 |
| `ENCRYPTED` | 6 | `COLUMN` | 7 |
| `SENSITIVE` | 8 | `VECTOR` | 9 |
| `USER_DEFINED` | 128 | | |

`bson.vector(values, dtype [, padding]) -> binary`

This constructor returns BSON binary subtype `VECTOR`. `values` can be a dense Lua array or a
BSON array. `dtype` must be one of the immutable `bson.VECTOR_DTYPE` constants:

| Name | Value | Input contract |
|---|---:|---|
| `INT8` | 0x03 | Integers from -128 through 127. |
| `FLOAT32` | 0x27 | Lua numbers, rounded to their encoded IEEE-754 binary32 values. |
| `PACKED_BIT` | 0x10 | Bytes from 0 through 255; `padding` is 0 through 7 ignored low bits in the final byte. |

`padding` defaults to zero, must be zero for `INT8` and `FLOAT32`, and cannot describe nonzero
ignored bits or an empty `PACKED_BIT` value.

`binary:as_vector() -> vector`

This method accepts only binary subtype `VECTOR` and validates the encoded dtype, padding, and
payload length. It returns an immutable value with `dtype`, `padding`, and `data` fields;
`data` is a BSON array. A non-vector subtype or malformed vector payload is programmer misuse
of this accessor and raises.

### Exact numeric values

Lua integers passed directly to the encoder use BSON int32 when in range and BSON int64
otherwise. This preserves the full signed 64-bit Lua integer range required by the driver.
Lua floats use BSON double. Decoding always returns an exact numeric wrapper, which preserves
the BSON wire type and can be passed back to the encoder unchanged.

| Constructor or method | Contract |
|---|---|
| `bson.int32(number) -> int32` | Requires a Lua integer in the signed 32-bit range. |
| `bson.int64(number) -> int64` | Requires a Lua integer; all supported runtimes have 64-bit integers. |
| `bson.double(number) -> double` | Requires a Lua number and preserves its encoded binary64 representation, including signed zero and NaN payload identity. |
| `exact_number:to_number() -> number` | Returns the Lua integer or float held by an int32, int64, or double. |
| `bson.decimal128(input) -> decimal128` | Parses a non-empty exact decimal string, including signed zero, infinity, NaN, and signaling NaN spellings. |
| `bson.decimal128_from_bid(bytes) -> decimal128` | Requires the exact 16-byte Decimal128 BID representation. |
| `decimal128:bid_hex() -> string` | Returns the 32 lowercase hexadecimal digits of the BID representation. |

Int32, int64, and double values expose read-only `kind`, `value`, and `bytes` fields.
Decimal128 values expose read-only `kind`, `string`, and `bid` fields; `tostring(decimal)`
returns its canonical string representation. Decimal construction raises if the input is
malformed, outside Decimal128 range, has more than 34 significant digits, or would require
inexact rounding.

### Tagged values and singletons

| Constructor | Read-only fields and contract |
|---|---|
| `bson.object_id(input) -> object_id` | Accepts a 12-byte string or 24 hexadecimal characters; exposes `binary`, lowercase `hex`, `kind`, and unsigned `timestamp`. `tostring` returns the hex value, and ObjectIds support equality and byte-order comparison. |
| `bson.datetime(milliseconds) -> datetime` | Requires a signed 64-bit Lua integer; exposes `kind` and `milliseconds` and supports equality and chronological comparison. |
| `bson.regex(pattern [, options]) -> regex` | `pattern` is a NUL-free string; options use only `i`, `l`, `m`, `s`, `u`, and `x` and are deduplicated into that order. Exposes `kind`, `pattern`, and `options`. |
| `bson.timestamp(time, increment) -> timestamp` | Both values are integers from 0 through 2^32-1; exposes `kind`, `time`, and `increment` and compares time before increment. |
| `bson.code(source [, scope]) -> code` | `source` is a string and optional `scope` is an ordered BSON document; exposes `kind`, `source`, and `scope`. |
| `bson.symbol(value) -> symbol` | Represents the deprecated BSON Symbol type and exposes `kind` and string `value`. |
| `bson.db_pointer(namespace, object_id) -> db_pointer` | Represents the deprecated BSON DBPointer type and exposes `kind`, string `namespace`, and `object_id`. |

The public immutable singletons are `bson.null`, `bson.undefined`, `bson.min_key`, and
`bson.max_key`. Null is distinct from Lua nil. Undefined, Symbol, and DBPointer remain
available so existing BSON can round-trip even though those wire types are deprecated.

`bson.object_id_generator(runtime) -> generator | nil, err`

The supplied runtime must satisfy the advanced runtime contract. Construction reads eight
entropy bytes: five process-unique bytes and a three-byte initial counter. Entropy failure
returns `nil, err`; an invalid runtime result raises.

`generator:new() -> object_id | nil, err`

Generation uses the runtime wall clock, current process identity, and a wrapping 24-bit
counter. When the process identity changes after a fork, the generator refreshes its five
process-unique entropy bytes before returning another value. That refresh can return
`nil, err`. Invalid time, identity, or entropy results raise.

### BSON predicates

- `bson.is_document(value) -> boolean`
- `bson.is_array(value) -> boolean`
- `bson.is_binary(value) -> boolean`
- `bson.is_null(value) -> boolean`
- `bson.is_exact(value [, kind]) -> boolean`, where `kind` can be `int32`, `int64`,
  `double`, or `decimal128`.
- `bson.is_tagged(value [, kind]) -> boolean`, where `kind` can be `object_id`,
  `datetime`, `regex`, `timestamp`, `code`, `symbol`, `db_pointer`, `undefined`,
  `min_key`, or `max_key`.

With no `kind` argument, the last two predicates accept any value in their respective family.
An unknown kind simply does not match.

### BSON binary codec

- `bson.encode(document [, options]) -> bytes | nil, err` encodes one ordered root document.
- `bson.decode(bytes [, options]) -> document | nil, err` decodes exactly one complete root
  document and rejects trailing bytes.

The shared options table has these fields:

| Option | Default | Contract |
|---|---:|---|
| `max_document_size` | 16 MiB | Maximum encoded or decoded document size in bytes. |
| `max_binary_size` | 16 MiB | Maximum binary payload size in bytes. |
| `max_string_size` | 16 MiB | Maximum string, code, regex, or namespace size in bytes. |
| `max_depth` | 100 | Maximum document and array nesting depth. |
| `validate_utf8` | true | Validate strings and applicable keys on encode and decode; false enables byte-preserving strings. |

Size and depth options must be positive signed 32-bit integers, `validate_utf8` must be
boolean, and unknown options raise. Encoding accepts BSON values plus Lua strings, booleans,
integers, and floats. An ambiguous or unsupported Lua value, a non-document root, an over-limit
value, or invalid UTF-8 returns `nil` and a structured `BSON`-category error. Malformed BSON
bytes, unsupported wire types, limit violations, invalid UTF-8, and trailing data do the same.
A non-string decode input raises.

### JSON and Extended JSON

`mongodb.bson.json` is available as `bson.json` and through
`require("mongodb.bson.json")`.

- `bson.json.parse(text [, options]) -> value | nil, err` parses plain JSON into ordered BSON
  documents, BSON arrays, `bson.null`, strings, booleans, and exact int32, int64, or double
  values. It does not interpret Extended JSON wrapper objects.
- `bson.json.decode(text [, options]) -> value | nil, err` parses JSON and recursively
  interprets recognized Extended JSON wrappers. Wrapper objects require their exact field set,
  and decoded JSON object keys must be unique.
- `bson.json.encode(value [, options]) -> text | nil, err` writes ordered BSON containers and
  supported BSON values as Extended JSON.

The shared JSON options are `mode` (`"relaxed"` by default or `"canonical"`),
`max_depth` (200), `max_input_size` (16 MiB), and `max_string_size` (16 MiB). The maximum input
size also bounds encoded output. Numeric limits must be positive integers, unknown options
raise, and `mode` affects encoding:

- Canonical mode writes int32, int64, and double with explicit Extended JSON wrappers and
  writes dates using a wrapped `$numberLong` value.
- Relaxed mode writes integers and finite doubles as JSON numbers when possible and writes
  dates from years 1970 through 9999 as ISO-8601 strings. Decimal128 and non-finite doubles
  remain wrapped.

Both modes use Extended JSON wrappers for binary, ObjectId, regular expression, timestamp,
code with optional scope, MinKey, MaxKey, undefined, symbol, and DBPointer. Decoding also
accepts `$uuid` and the canonical numeric and date forms.

Malformed BSON and JSON input returns a structured BSON error.
Invalid constructor arguments and codec options raise.
JSON parsing and encoding also return structured BSON errors for syntax failures, malformed
wrapper objects, unsupported values, invalid UTF-8, and configured size or depth limits.

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
