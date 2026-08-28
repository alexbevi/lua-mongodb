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
| `mongodb.runtime.gssapi` | Optional system GSSAPI provider. |
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
error. A non-string URI or non-table options value raises. Invalid normalized settings,
including unknown programmatic option names, return a configuration error; malformed extension
objects such as runtimes, listeners, and driver metadata raise. The complete option and handle
contracts are specified below.

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

## Client and database handles

Client, database, and collection handles are immutable. Methods use colon syntax.
Database and collection handles borrow the client lifetime: they do not have independent
`close` methods and must not outlive their client. Operations attempted through any of those
handles after the client closes return `nil` and a `CLIENT`-category error.

### Client construction

`mongodb.client(uri [, options]) -> client | nil, err`

Programmatic client options use `snake_case`. URI options keep the spelling defined by the
MongoDB connection-string specification and are case-insensitive.
Programmatic values take precedence over URI options. Unsupported, duplicated, deprecated, or
recoverably invalid URI options are reported in the client's immutable `warnings` array. An
unavailable requested Snappy or Zstandard provider also produces a warning.

The constructor copies and normalizes configuration values. It retains extension callbacks,
the supplied runtime, and listener objects for the lifetime of the client. The complete
programmatic option set is:

| Option | Default | Contract |
|---|---|---|
| `app_name` | unset | Non-empty UTF-8 string of at most 128 bytes, included in handshake metadata. |
| `auth_mechanism` | inferred | Non-empty authentication-mechanism string. |
| `auth_mechanism_properties` | unset | Table of mechanism properties; values are strings except supported OIDC callback and allowed-host fields and the GSSAPI canonicalization boolean. |
| `auth_source` | inferred | Non-empty authentication database name. |
| `cancellation` | unset | Cancellation value from the selected runtime, used while constructing and initially connecting the client. |
| `command_listeners` | empty | Dense array of tables with optional `started`, `succeeded`, and `failed` callbacks. |
| `compressors` | empty | Dense array containing `snappy`, `zlib`, and/or `zstd` in negotiation order. |
| `connect_timeout_ms` | 10000 | Non-negative integer per-connect timeout in milliseconds; zero is unbounded. |
| `deadline` | unset | Absolute deadline from the selected runtime's monotonic clock for client construction. |
| `direct_connection` | false | Boolean; true requires one seed and is incompatible with load-balanced and SRV modes. |
| `driver_info` | unset | Table with required non-empty `name` and optional `version` and `platform` strings for wrapper metadata. |
| `heartbeat_frequency_ms` | 10000 | Integer of at least 500 milliseconds. |
| `heartbeat_listeners` | empty | Dense array of listener functions or event-callback tables for server-heartbeat events. |
| `local_threshold_ms` | 15 | Non-negative integer latency-window threshold in milliseconds. |
| `load_balanced` | false | Boolean; true requires one seed and excludes `direct_connection` and `replica_set`. |
| `logging` | environment or off | Table configuring structured component levels, output, and document truncation as described below. |
| `max_connecting` | 2 | Positive integer concurrent connection-creation limit per pool. |
| `max_idle_time_ms` | 0 | Non-negative integer idle lifetime; zero disables idle-time expiry. |
| `max_pool_size` | 100 | Non-negative integer pool limit; zero is unbounded. |
| `min_pool_size` | 0 | Non-negative integer; cannot exceed a nonzero `max_pool_size`. |
| `on_listener_error` | unset | Function called with an error raised by a monitoring callback; its own errors are suppressed. |
| `pool_listeners` | empty | Dense array of listener functions or event-callback tables for connection-pool events. |
| `read_concern` | empty | Table with optional string `level`. |
| `read_preference` | primary | Table with `mode`, `tag_sets`, and `max_staleness_seconds`; see concern shapes below. |
| `replica_set` | unset | Non-empty replica-set name. |
| `retry_reads` | true | Boolean enabling retryable reads where the operation permits them. |
| `retry_writes` | true | Boolean enabling retryable writes where the operation permits them. |
| `runtime` | default Copas runtime | Caller-owned value satisfying the advanced runtime contract. |
| `sdam_listeners` | empty | Dense array of listener functions or event-callback tables for SDAM events. |
| `server_api` | unset | Table with `version = "1"` and optional boolean `strict` and `deprecation_errors`. |
| `server_monitoring_mode` | `auto` | One of `auto`, `poll`, or `stream`. |
| `server_selection_timeout_ms` | 30000 | Non-negative integer server-selection timeout in milliseconds. |
| `server_selection_try_once` | true | Boolean controlling single-threaded server-selection retry behavior. |
| `socket_timeout_ms` | unset | Non-negative integer socket-operation timeout in milliseconds; zero is unbounded. |
| `srv_max_hosts` | 0 | Non-negative integer SRV host limit; valid only with `mongodb+srv` and zero is unlimited. |
| `srv_service_name` | `mongodb` | DNS service label, at most 62 bytes and valid only with `mongodb+srv`. |
| `timeout_ms` | unset | Inherited non-negative client-side operation timeout; zero is unbounded. |
| `tls` | false, true for SRV unless specified | Boolean enabling TLS. Supplying another `tls_*` option also enables it. |
| `tls_allow_invalid_certificates` | false | Boolean disabling certificate-chain validation. |
| `tls_allow_invalid_hostnames` | false | Boolean disabling certificate-hostname validation. |
| `tls_ca_file` | runtime default | Non-empty CA-file path. |
| `tls_certificate_key_file` | unset | Non-empty client certificate/private-key file path. |
| `tls_certificate_key_file_password` | unset | Non-empty password for the client key file. |
| `tls_disable_certificate_revocation_check` | false | Boolean disabling certificate revocation checks. |
| `tls_disable_ocsp_endpoint_check` | false | Boolean disabling OCSP endpoint checks. |
| `tls_insecure` | false | Boolean enabling the driver's combined insecure TLS policy. |
| `wait_queue_timeout_ms` | 0 | Non-negative integer pool checkout timeout; zero is unbounded. |
| `write_concern` | empty | Table with optional `journal`, `w`, and `w_timeout_ms` fields. |
| `zlib_compression_level` | -1 | Integer from -1 through 9. |

Command listeners observe application command I/O. A successful `database:run_command` invokes
`started` with the exact command document, command name, and database name, then invokes `succeeded`
with the reply and the same command name. Both events share their request, operation, and connection
identities. Handshakes and monitor heartbeats remain outside this listener path.
When the server's hello response contains `connectionId`, every started event and its terminal
succeeded or failed event expose that value as `server_connection_id`.

Single-batch collection finds use the same listener path. The started event retains the filter and
declared find options, while the succeeded event retains the server's cursor reply and first batch.
If iteration requires another batch, listeners receive a correlated `getMore` started and succeeded
pair with the cursor identifier, collection name, batch size, and server reply.
When the server rejects a find, listeners receive the started event followed by a correlated failed
event; the collection operation still returns its structured MongoDB error.
An `insert_one` publishes the encoded insert command and the server reply. Replies that contain
`writeErrors` still produce a succeeded event, while the collection operation retains its existing
write-error result.
`insert_many` applies the same event contract to each emitted wire batch. A batch reply containing
`writeErrors` is a command success even though the collection operation returns a write error.
`delete_one` publishes a delete command whose sole delete specification has `limit = 1`, followed
by the server reply. A reply containing `writeErrors` still produces a succeeded event while the
collection operation returns its structured write error.
`delete_many` follows the same contract with `limit = 0` in its delete specification.
`update_one` publishes one update specification with single-document semantics. Ordinary, upsert,
and `writeErrors` replies all produce succeeded events; upsert identifiers and structured write
errors remain available through the collection operation's existing result contract.
`update_many` follows the same event and result contract with `multi = true` in its update
specification.
A mixed collection `bulk_write` publishes one correlated lifecycle for each emitted wire command
in execution order. Batching and result aggregation are unchanged by observation.
For an unacknowledged collection bulk, the driver publishes a synthetic succeeded event after the
no-response write. Its reply contains `ok = 1` and does not fabricate an affected-document count.
An unacknowledged client `bulk_write` follows the same rule for its `bulkWrite` command. Its result
exposes `acknowledged = false`; count and verbose-result fields remain absent.
A reply containing `writeConcernError` is still a succeeded command event. If retry policy causes
another attempt, each attempt publishes its own started and succeeded pair.

#### Structured logging configuration

The `logging` table accepts only these fields:

| Field | Contract |
|---|---|
| `levels` | Table whose keys are `all`, `command`, `connection`, `server_selection`, or `topology`, and whose values are `off`, `emergency`, `alert`, `critical`, `error`, `warn`, `notice`, `info`, `debug`, or `trace`, case-insensitively. A component value overrides `all`. |
| `destination` | `stdout` or `stderr`, case-insensitively. Cannot be combined with `sink`. |
| `sink` | `sink(event)` callback retained for the client lifetime and used instead of the runtime output destination. Cannot be combined with `destination`. Callback failures are suppressed. |
| `max_document_length` | Non-negative integer maximum for each logged Extended JSON document; the default is 1000 Unicode code points. |

Programmatic fields override the corresponding environment values. The environment fallback
uses `MONGODB_LOG_ALL`, `MONGODB_LOG_COMMAND`, `MONGODB_LOG_CONNECTION`,
`MONGODB_LOG_SERVER_SELECTION`, `MONGODB_LOG_TOPOLOGY`, `MONGODB_LOG_PATH`, and
`MONGODB_LOG_MAX_DOCUMENT_LENGTH`. Logging defaults to off and stderr. Invalid environment
values are ignored, while invalid programmatic values return a configuration-category error
from client construction.

Each sink event is immutable and exposes `component`, `level`, and `data` fields. `component` is
`command`, `connection`, `serverSelection`, or `topology`; `level` is the lowercase severity;
and `data` is an immutable map whose field names and casing come directly from the corresponding
MongoDB specification. Fields without values are omitted. BSON document fields are redacted when
required, rendered as relaxed Extended JSON, and then truncated at the configured Unicode-code-point
boundary with a trailing `...`. The ellipsis does not count toward the limit.

Without a custom sink, each enabled event is written through `runtime.output` as one compact JSON
object with the same `component`, `level`, and `data` envelope. Logging is observational: document
rendering, callback, and output failures are suppressed and cannot change the driver operation that
produced the event. Logging component names are part of the supported configuration contract, but
individual message contents may evolve within their specification requirements. The configuration,
sink, and event envelope are independent of component emission. The command component emits
`Command started`, `Command succeeded`, and `Command failed` messages at `debug`. Every message
contains `commandName`, `databaseName`, `requestId`, `operationId`, `serverHost`, and `serverPort`.
A multi-command bulk operation reuses one operation ID across all of its command lifecycles. Other
commands use their request-derived operation ID. Started
messages add the relaxed Extended JSON `command`; succeeded messages add `durationMS` and the
relaxed Extended JSON `reply`; failed messages add `durationMS` and `failure`. An unacknowledged
write emits a succeeded message with an `{ "ok": 1 }` reply after the complete OP_MSG has been
written. For pooled commands, the pool's integer connection ID appears as `driverConnectionId` on
the started message and its terminal succeeded or failed message. When the server returns a
`connectionId` in its hello response, those messages also contain it as `serverConnectionId`. Each
load-balanced command message contains the checked-out connection's `serviceId` as a hexadecimal
string; other topologies omit it. Each started message has exactly one terminal message with the
same request ID. Connection handshakes and monitor heartbeats never enter command logs. Their
independent CMAP and SDAM events remain available.
This surface covers every pinned command logging and monitoring case applicable to the MongoDB 7.0
production floor; the two older cursor-kill and `getnonce` branches are outside that floor.
Server-selection, topology, and connection messages are enabled only by their component-specific
implementation slices.

Command logs replace command and reply documents with `{}` for `authenticate`, `saslStart`,
`saslContinue`, `getnonce`, `createUser`, `updateUser`, `copydbgetnonce`, `copydbsaslstart`, and
`copydb`. They apply the same rule to `hello`, `ismaster`, and `isMaster` when the command contains
`speculativeAuthenticate`. A sensitive server failure retains only `code`, `codeName`, and
`errorLabels`. Network and other client-side failures remain visible because they contain no server
authentication response.

`read_preference.mode` is `primary`, `primary_preferred`, `secondary`,
`secondary_preferred`, or `nearest`. `tag_sets` is a dense array of string-to-string tables.
`max_staleness_seconds` is -1 or an integer of at least 90. Primary mode cannot use tags or
max staleness. `write_concern.journal` is boolean; `w` is a non-negative integer or non-empty
string; `w_timeout_ms` is a non-negative integer. `w = 0` cannot be combined with
`journal = true`. Conflicting permissive TLS options return a configuration error.

GSSAPI configuration requires a non-empty username, always uses `$external`, and permits an
optional password. Its mechanism properties are case-insensitive: `SERVICE_NAME` defaults to
`mongodb`; `SERVICE_HOST` and `SERVICE_REALM` are optional strings; and
`CANONICALIZE_HOST_NAME` accepts `none`, `forward`, `forwardAndReverse`, `true`, or `false`.
The legacy boolean values normalize to `forwardAndReverse` and `none`. The default Copas
runtime lazily loads the packaged system GSSAPI adapter on Linux and macOS when the operating
system library is available. Constructing a client does not contact a KDC. The verified default
provider matrix covers Lua 5.4 on Ubuntu 24.04. macOS and Lua 5.5 can build and load the package,
but they are not GSSAPI support claims without recurring Kerberos-enabled MongoDB profiles.

`driver_info` fields must be valid UTF-8 and cannot contain `|`. Its `name` is required.
Listener arrays must be dense. Command listener methods receive the listener as `self` and an
immutable event; the other listener families accept either a function receiving the event or a
table callback receiving `self` and the event.

### Handle configuration, timeouts, and ownership

`client:database([name [, options]]) -> database | nil, err`

`name` defaults to the database in the connection URI. If neither is present, the method
returns a client error. Database names must be non-empty valid UTF-8 and cannot contain NUL,
space, `"`, `/`, `\`, or `$`; `$external` is the allowed dollar-name exception. Namespace
misuse raises.

`database:collection(name [, options]) -> collection | nil, err`

Collection names must be non-empty valid UTF-8, cannot contain NUL or `..`, and cannot begin or
end with `.`. Dollar names are rejected except `$cmd`, `$cmd.*`, and `oplog.$main*`.

Both handle constructors accept only `read_concern`, `read_preference`, `write_concern`, and
`timeout_ms`. Omitted values inherit from the parent handle; supplied values use the normalized
client option shapes above. An invalid value returns a configuration error. A non-table option
value or unknown key raises. Database handles expose read-only `name`, `read_concern`,
`read_preference`, `write_concern`, and `timeout_ms` values.

Every operational method below accepts `timeout_ms` in addition to its listed options. It must
be a non-negative integer, overrides the handle default, and uses zero for no client-side
deadline. A positive value creates one absolute operation deadline shared by server selection,
pool checkout, network work, retries, and cursor continuation. An explicit `deadline` is an
absolute monotonic runtime deadline; when both bounds exist, the earlier one wins.
`cancellation` is a cancellation value from the client's runtime. `session` is a session from
the same client.

Cursor-producing methods that list `timeout_mode` accept `cursor_lifetime` or `iteration` and
require an effective `timeout_ms`. Cursor-lifetime mode keeps the original operation deadline;
iteration mode refreshes the budget for each cursor iteration where supported. Change streams
and write aggregations reject unsupported timeout-mode combinations with a client error.
Unknown operation options and invalid caller value types raise.

Closing a client closes its registered cursors and sessions, sends a best-effort `endSessions`
command, and closes its MongoDB executor, pools, sockets, and monitor tasks. It does not close a
caller-supplied runtime.

- `client:close() -> boolean` returns true for the first close. A repeated close returns false.
- `client:is_closed() -> boolean` reports the current state.
- `client:append_metadata(driver_info) -> boolean | nil, err` applies the `driver_info` shape
  above to future connections. It returns true for a new tuple, false for an exact duplicate,
  and `nil, err` if the client is closed or metadata updates are unavailable.

### Client methods

`client:start_session([options]) -> session | nil, err`

Options are `causal_consistency` (boolean), `snapshot` (boolean), `snapshot_time` (BSON
timestamp), `default_transaction_options` (table), and `timeout_ms` (non-negative integer).
Causal consistency defaults to true except for snapshot sessions. `snapshot_time` requires
`snapshot = true`, and snapshot mode cannot use causal consistency. The timeout inherits from
the client when omitted. The method returns a client error after close or when the deployment
does not support sessions; creating the session can otherwise return an entropy error. Session
methods are specified in the session reference.

`client:list_databases([options]) -> cursor | nil, err`

Options are `authorized_databases` and `name_only` (booleans), `filter` (BSON document),
`comment`, `session`, `cancellation`, `deadline`, and `timeout_ms`. The command runs against
`admin`, forces primary selection, and is retryable. The cursor yields the server's database
description documents.

`client:list_database_names([options]) -> names | nil, err`

Accepts the same options as `list_databases`, forces `name_only = true`, consumes the cursor,
and returns an immutable ordered array of non-empty names.

`client:drop_database(name_or_database [, options]) -> true | nil, err`

The target is a valid database-name string or a database handle. Options are `comment`,
`max_time_ms` (non-negative integer), `session`, `cancellation`, `deadline`, and `timeout_ms`.
The operation uses the client's write concern and returns true after successful dispatch.

`client:bulk_write(models [, options]) -> result | nil, err`

`models` is a non-empty dense array of `mongodb.client_bulk` models and requires MongoDB 8.0
or newer. Options are `bypass_document_validation` (boolean), `comment`, `let` (BSON
document), `ordered` (boolean, default true), `session`, `verbose_results` (boolean, default
false), `write_concern`, `cancellation`, `deadline`, and `timeout_ms`. Unacknowledged writes
cannot be ordered, verbose, or use an explicit session. Model and result fields are specified
in the bulk reference.

`client:watch([pipeline [, options]]) -> change_stream | nil, err`

This opens a cluster-wide change stream. `pipeline` defaults to an empty BSON array and each
stage must be a BSON document. The shared watch options described below apply.

### Database methods

`database:gridfs_bucket([options]) -> bucket | nil, err`

This is the database-bound form of `mongodb.gridfs_bucket` and accepts `bucket_name`,
`chunk_size_bytes`, `disable_md5`, `read_concern`, `read_preference`, `timeout_ms`, and
`write_concern`. The GridFS reference specifies bucket methods.

`database:create_collection(name [, options]) -> collection | nil, err`

The name follows the collection-name rules above. Options are:

- booleans: `capped`;
- non-negative integers: `expire_after_seconds`, `max`, and `size`;
- BSON documents: `change_stream_pre_and_post_images`, `clustered_index`, `collation`,
  `index_option_defaults`, `timeseries`, and `validator`;
- `pipeline`, a BSON array of BSON document stages;
- `view_on`, a non-empty string;
- `validation_action`, `error` or `warn`;
- `validation_level`, `off`, `strict`, or `moderate`; and
- `comment`, `session`, `cancellation`, `deadline`, and `timeout_ms`.

The command uses the database write concern. Success returns a collection handle inheriting
the database handle's settings, not operation-only options.

`database:modify_collection(name [, options]) -> document | nil, err`

Options are `change_stream_pre_and_post_images`, `index`, and `validator` (BSON documents);
`validation_action` (`error` or `warn`); `validation_level` (`off`, `strict`, or `moderate`);
and `comment`, `session`, `cancellation`, `deadline`, and `timeout_ms`. The command uses the
database write concern and returns the server response.

`database:drop_collection(name_or_collection [, options]) -> true | nil, err`

The target is a valid collection-name string or a collection handle belonging to this database.
A handle from another database raises. Options are `comment`, `max_time_ms` (non-negative
integer), `session`, `cancellation`, `deadline`, and `timeout_ms`. The command uses the
database write concern. Server code 26 (`NamespaceNotFound`) is treated as success.

`database:list_collections([options]) -> cursor | nil, err`

Options are `authorized_collections` and `name_only` (booleans), `batch_size` (non-negative
integer), `filter` (BSON document), `comment`, `session`, `cancellation`, `deadline`,
`timeout_ms`, and `timeout_mode`. The command forces primary selection and pins its selected
connection until the cursor closes. `comment` applies to `listCollections` but is not inherited
by `getMore`.

`database:list_collection_names([options]) -> names | nil, err`

Accepts the same options as `list_collections`, consumes its cursor, and returns an immutable
ordered array of non-empty names. The driver requests `nameOnly` when the filter is absent,
empty, or contains only a `name` predicate.

`database:run_command(command [, options]) -> document | nil, err`

`command` is a non-empty command-name string or non-empty BSON document. Options are
`read_preference`, `session`, `cancellation`, `deadline`, and `timeout_ms`. Generic commands
default to primary selection even when the database has another read preference. An explicit
read preference uses the normalized shape above.
Generic commands do not append inherited read or write concerns; place command-specific
concern fields in the supplied BSON document.

`database:run_cursor_command(command [, options]) -> cursor | nil, err`

The command forms are the same as `run_command`, but the response must contain a valid cursor.
Options are `batch_size` (positive integer), `comment`, `cursor_type` (`non_tailable` or
`tailable`), `max_await_time_ms` (non-negative integer), `read_preference`, `session`,
`cancellation`, `deadline`, `timeout_ms`, and `timeout_mode`. `batch_size`, `comment`, and
`max_await_time_ms` configure `getMore` rather than rewriting the initial command. The selected
connection remains pinned until the cursor closes. `tailable_await` is recognized only to
return a client error because it is outside the supported generic-command API; tailable cursors
also reject cursor-lifetime timeout mode.

`database:aggregate(pipeline [, options]) -> cursor | nil, err`

`pipeline` is a BSON array of BSON document stages. Options are `allow_disk_use` and
`bypass_document_validation` (booleans), `batch_size`, `max_await_time_ms`, and `max_time_ms`
(non-negative integers), `collation` and `let` (BSON documents), `hint` (index name or BSON
document), `comment`, `session`, `cancellation`, `deadline`, `timeout_ms`, and `timeout_mode`.
A read pipeline inherits the database read concern and read preference and can be retried once.
A pipeline containing `$out` or `$merge` uses write selection and the database write concern,
is not retryable, and rejects iteration timeout mode. When a positive timeout applies,
`max_await_time_ms` must be lower than `timeout_ms`.

`database:watch([pipeline [, options]]) -> change_stream | nil, err`

This opens a database-wide change stream. `pipeline` has the same shape as client watch.
Shared watch options are `allow_disk_use` and `bypass_document_validation` (booleans),
`batch_size`, `max_await_time_ms`, and `max_time_ms` (non-negative integers), `collation` and
`let` (BSON documents), `hint` (index name or BSON document), `comment`, `session`,
`cancellation`, `deadline`, and `timeout_ms`. Change-stream stage options are
`full_document` and `full_document_before_change` (strings), `resume_after` and `start_after`
(BSON documents), `start_at_operation_time` (BSON timestamp), and `show_expanded_events`
(boolean). `timeout_mode` is unsupported, and `max_await_time_ms` must be lower than a positive
`timeout_ms`. Iteration and resume behavior are specified in the change-stream reference.

## Collection and administration APIs

Collection operations inherit `read_concern`, `read_preference`, `write_concern`, and `timeout_ms`
from the collection handle unless an operation's contract says otherwise. The handle rules are
the one authoritative timeout, cancellation, session, and error contract for every operation
below; see [handle configuration](#handle-configuration-timeouts-and-ownership). In particular,
every method accepts `timeout_ms`, `deadline`, `cancellation`, and `session` even when those
common options are not repeated in its method-specific list.
`raw_data` is an internal conformance option and is not part of the supported application API.

Collection handles additionally expose read-only `name`, `full_name`, `read_concern`,
`read_preference`, `write_concern`, and `timeout_ms` properties. Documents, filters,
projections, pipelines, collations, hints, and other BSON-shaped values below use
`mongodb.bson` values, not ordinary Lua tables.

### Write results

Write result objects and their nested identifier maps are immutable. Fields that do not apply to
an operation are nil. Unacknowledged results expose only `acknowledged = false`; count and
identifier fields are unavailable because no server response was requested.

| Field | Meaning |
|---|---|
| `acknowledged` | Whether the server acknowledged the write. |
| `inserted_id` | Identifier of the document written by `insert_one`. |
| `inserted_ids` | One-based immutable identifier map returned by acknowledged `insert_many`. |
| `inserted_count` | Number of documents inserted by a bulk operation. |
| `matched_count` | Number of documents matched by an update or replacement. |
| `modified_count` | Number of documents modified by an update or replacement. |
| `deleted_count` | Number of documents deleted. |
| `upserted_count` | Number of documents created by upserts. |
| `upserted_id` | Identifier created by a single update or replacement upsert. |
| `upserted_ids` | Immutable model-index-to-identifier map for bulk upserts. |

`collection:insert_one(document [, options]) -> result | nil, err`

`document` must be a BSON document. The driver generates an ObjectId when `_id` is absent and
returns an entropy error if generation fails. Options are `bypass_document_validation`
(boolean), `comment`, and the common operation options. An acknowledged result exposes
`acknowledged` and `inserted_id`; the operation is retryable when acknowledged.

`collection:insert_many(documents [, options]) -> result | nil, err`

`documents` is a non-empty dense Lua array of BSON documents. The driver generates missing
identifiers before batching. Options are `bypass_document_validation` and `ordered` (booleans;
ordered defaults to true), `comment`, and the common operation options. An acknowledged result
exposes `acknowledged`, all five bulk counts, `upserted_ids`, and `inserted_ids`.

`collection:bulk_write(models [, options]) -> result | nil, err`

`models` is a non-empty dense Lua array constructed with `mongodb.bulk`. Options are
`bypass_document_validation` and `ordered` (booleans; ordered defaults to true), `comment`, `let`
(BSON document), and the common operation options. An acknowledged result exposes
`acknowledged`, `inserted_count`, `matched_count`, `modified_count`, `deleted_count`,
`upserted_count`, and `upserted_ids`. Ordered execution stops after the first write error;
unordered execution reports all errors it receives. Bulk model constructors and partial-result
error fields are specified in the bulk reference.

Unacknowledged collection writes reject collation and array filters. Bulk writes also reject
`bypass_document_validation = true`; hint and update-sort support remains subject to the server
version. An explicit session can make a write acknowledged while it participates in a
transaction.

### Queries and cursors

`collection:find([filter [, options]]) -> cursor | nil, err`

`filter` defaults to an empty BSON document. Options are:

- booleans: `allow_disk_use`, `allow_partial_results`, `no_cursor_timeout`, `return_key`, and
  `show_record_id`;
- non-negative integers: `batch_size`, `max_await_time_ms`, `max_time_ms`, and `skip`;
- BSON documents: `collation`, `let`, `max`, `min`, `projection`, and `sort`;
- `hint`, an index name or BSON document; `comment`, any BSON value; `limit`, an integer;
  `cursor_type`, one of `non_tailable`, `tailable`, or `tailable_await`; `timeout_mode`; and the
  common operation options.

A negative limit requests a single batch and its absolute value is the result limit. The cursor
pins its selected connection until close, inherits `comment` for `getMore`, and uses the
collection read concern and read preference. Tailable cursor iteration and timeout constraints
are specified in the cursor reference.

`collection:find_one([filter [, options]]) -> document | nil, err`

This accepts the `find` options except `cursor_type` and `max_await_time_ms`; it forces a
one-document, single-batch query. A nil filter becomes an empty document, while any other
non-document filter is shorthand for `{ _id = filter }`. The method returns one Lua nil with no
error when no document matches.

### Updates and deletes

`collection:update_one(filter, update [, options]) -> result | nil, err`

`collection:update_many(filter, update [, options]) -> result | nil, err`

`filter` is a BSON document. `update` is either a non-empty modifier document whose first key
begins with `$`, or a non-empty BSON array of pipeline-stage documents. Options are
`array_filters` (BSON array of documents), `bypass_document_validation` and `upsert` (booleans),
`collation`, `let`, and `sort` (BSON documents), `hint` (index name or BSON document), `comment`,
and the common operation options. `update_many` does not accept `sort` and is not retryable;
an acknowledged `update_one` is retryable.

`collection:replace_one(filter, replacement [, options]) -> result | nil, err`

`filter` and `replacement` are BSON documents, and the replacement cannot begin with an atomic
`$` modifier. It accepts the update options except `array_filters`. An acknowledged replacement
is retryable.

Acknowledged update and replacement results expose `acknowledged`, `matched_count`,
`modified_count`, `upserted_count`, and `upserted_id`.

`collection:delete_one(filter [, options]) -> result | nil, err`

`collection:delete_many(filter [, options]) -> result | nil, err`

`filter` is a BSON document. Options are `collation` and `let` (BSON documents), `hint` (index
name or BSON document), `comment`, and the common operation options. An acknowledged
`delete_one` is retryable; `delete_many` is not. Acknowledged results expose `acknowledged` and
`deleted_count`.

### Aggregation, counts, and find-and-modify

`collection:aggregate(pipeline [, options]) -> cursor | nil, err`

`pipeline` and options have the same shapes as
[`database:aggregate`](#database-methods). Read pipelines use the collection read concern and
read preference and are retryable. Pipelines containing `$out` or `$merge` use the write concern,
are not retryable, and reject iteration timeout mode.

`collection:watch([pipeline [, options]]) -> change_stream | nil, err`

This opens a collection-scoped change stream and accepts the shared pipeline and options listed
for `database:watch`. Change-stream iteration, resume, and lifecycle behavior are specified in
the change-stream reference.

`collection:count(filter [, options]) -> integer | nil, err`

This deprecated command requires a BSON document filter. Options are `collation` (BSON
document), `hint` (index name or BSON document), `limit`, `max_time_ms`, and `skip` (non-negative
integers), `comment`, and the common operation options. It uses the collection read concern and
read preference and is retryable.

`collection:count_documents(filter [, options]) -> integer | nil, err`

This exact count requires a BSON document filter and executes an aggregation. Options are
`collation` (BSON document), `hint` (index name or BSON document), `limit` (positive integer),
`max_time_ms` and `skip` (non-negative integers), `comment`, and the common operation options.
It returns zero when no documents match.

`collection:estimated_document_count([options]) -> integer | nil, err`

Options are `max_time_ms` (non-negative integer), `comment`, and the common operation options.
The command uses collection metadata, inherits the read concern, and is retryable.

`collection:distinct(key [, filter [, options]]) -> array | nil, err`

`key` is a non-empty string. `filter` defaults to an empty BSON document. Options are
`collation` (BSON document), `hint` (index name or BSON document), `max_time_ms` (non-negative
integer), `comment`, and the common operation options. The operation inherits the collection
read concern and is retryable; success returns a BSON array.

`collection:map_reduce(map, reduce, out [, options]) -> value | nil, err`

This deprecated operation accepts `map` and `reduce` as strings or BSON code. `out` is a
collection-name string or BSON document. Options are `bypass_document_validation`, `js_mode`,
and `verbose` (booleans); `collation`, `query`, `scope`, and `sort` (BSON documents); `finalize`
(string or BSON code); `limit` and `max_time_ms` (non-negative integers); `comment`; and the
common operation options. Inline output inherits the read concern and returns a BSON array;
collection output uses the write concern and returns the server's result value. Map-reduce is
never retried.

`collection:find_one_and_delete(filter [, options]) -> document | nil, err`

Options are `collation`, `let`, `projection`, and `sort` (BSON documents), `hint` (index name or
BSON document), `max_time_ms` (non-negative integer), `comment`, and the common operation
options.

`collection:find_one_and_replace(filter, replacement [, options]) -> document | nil, err`

This accepts the delete form's options plus `bypass_document_validation` and `upsert`
(booleans), and `return_document` (`before` or `after`, default `before`). `replacement` follows
the `replace_one` rules.

`collection:find_one_and_update(filter, update [, options]) -> document | nil, err`

This accepts the replacement form's options plus `array_filters` (BSON array of documents).
`update` follows the `update_one` rules. All three methods use the collection write concern and
are retryable when acknowledged. Each returns one Lua nil with no error when no document matches
or when the write is unacknowledged.

### Collection management

`collection:drop([options]) -> true | nil, err`

Options are `comment`, `max_time_ms` (non-negative integer), and the common operation options.
The command uses the collection write concern.
Server code 26 (`NamespaceNotFound`) is treated as success.

`collection:rename(new_name [, options]) -> document | nil, err`

`new_name` follows the collection-name rules. Options are `drop_target` (boolean), `comment`, and
the common operation options. The command runs against `admin`, uses the collection write
concern, and returns the server response document. The existing handle keeps its original name;
obtain a handle for the new namespace separately.

### Standard indexes

`collection:create_index(keys_or_model [, options]) -> name | nil, err`

`keys_or_model` is either a non-empty ordered BSON key document or a value returned by
`mongodb.index_model`. Key directions are 1, -1, `2d`, `2dsphere`, `geoHaystack`, `hashed`, or
`text`. With a key document, the following index options are accepted:

- booleans: `background`, `hidden`, `sparse`, and `unique`;
- non-negative integers: `bits`, `bucket_size`, `expire_after_seconds`, `text_index_version`,
  `two_dsphere_index_version`, and `version`;
- BSON documents: `collation`, `partial_filter_expression`, `storage_engine`, `weights`, and
  `wildcard_projection`;
- `default_language` and `language_override` (strings), `min` and `max` (numbers), and `name`
  (non-empty UTF-8 string without NUL).

Command options are `commit_quorum` (non-negative integer or non-empty string), `max_time_ms`
(non-negative integer), `comment`, and the common operation options. Index options cannot be
added when an existing model is supplied. Success returns the explicit or generated index name.

`collection:create_indexes(models [, options]) -> names | nil, err`

`models` is a non-empty dense Lua array of `mongodb.index_model` values. It accepts only the
command options above and returns an immutable ordered array of names. Both creation methods use
the collection write concern; `commit_quorum` requires MongoDB 4.4 or newer.

`collection:drop_index(name_or_model [, options]) -> true | nil, err`

`name_or_model` is a non-empty name or `mongodb.index_model`. The special name `*` is rejected;
use `drop_indexes`. Options are `comment`, `max_time_ms` (non-negative integer), and the common
operation options.

`collection:drop_indexes([options]) -> true | nil, err`

This accepts the same options as `drop_index`. Both methods use the collection write concern,
and server code 26 is success.

`collection:list_indexes([options]) -> cursor | nil, err`

Options are `batch_size` (non-negative integer), `comment`, `timeout_mode`, and the common
operation options. The selected connection remains pinned until cursor close and `comment` is
inherited by `getMore`. Server code 26 returns an empty cursor.

### Search indexes

`collection:create_search_index(model [, options]) -> name | nil, err`

`model` is a BSON document containing required `definition` (BSON document), optional `name`
(non-empty UTF-8 string without NUL), and optional `type` (`search` or `vectorSearch`). No other
fields are accepted. Options are the common operation options only.

`collection:create_search_indexes(models [, options]) -> names | nil, err`

`models` is a dense Lua array of those model documents. Options are the common operation options
only. Success returns an immutable ordered array of created names in model order.

`collection:update_search_index(name, definition [, options]) -> true | nil, err`

`name` is a non-empty UTF-8 string without NUL and `definition` is a BSON document. Options are
the common operation options only.

`collection:drop_search_index(name [, options]) -> true | nil, err`

`name` follows the same rules and options are the common operation options only. Server code 26
is success.

`collection:list_search_indexes([name [, options]]) -> cursor | nil, err`

`name`, when present, is a string. Options are `allow_disk_use` and
`bypass_document_validation` (booleans), `batch_size`, `max_await_time_ms`, and `max_time_ms`
(non-negative integers), `collation` and `let` (BSON documents), `hint` (index name or BSON
document), `comment`, `timeout_mode`, and the common operation options. The operation forces
primary selection, is retryable, pins its connection, and inherits `comment` for `getMore`.

Search index commands deliberately do not append the collection read or write concern; the
server applies its command defaults.

## Cursor and change-stream APIs

Find, aggregate, generic cursor-command, index-listing, and Search-index-listing methods return
the same immutable cursor type. A change stream wraps and owns one such cursor. Each cursor is
registered to its client and retains its connection pin and implicit session context while the
server cursor remains live. Buffered final documents can remain after those resources release.
Neither a cursor nor a change stream may outlive its client.
A stream owns its cursor but not its client or explicit session.
Closing a client closes every registered cursor and change stream before the executor, pools,
and runtime resources are released.

### Cursor iteration and state

`cursor:next() -> document | nil, err`

The method returns the next BSON document, `nil, err` on an operational failure, or one Lua nil
with no error for a non-document outcome. Interpret the nil outcome together with `is_closed()`:

| Result | Cursor state | Meaning |
|---|---|---|
| document | open or closed | A document was returned. A zero-id final batch closes as its last document is returned. |
| nil, nil | closed | The cursor is exhausted. |
| nil, nil | open tailable cursor | The server returned an empty live batch; polling can continue. |
| nil, err | inspect `is_closed()` | An operation failed; timeout, cancellation, and some server failures leave explicit cleanup possible. |

Ordinary cursors skip empty live batches and continue fetching until a document, exhaustion, or
error. `tailable` and `tailable_await` cursors instead advance through at most one server batch
per call. Tailable cursors return one Lua nil with no error after one empty live batch and remain
open. Call `is_closed()` to distinguish that result from exhaustion. `tailable_await` sends
`max_await_time_ms` as `maxTimeMS` on `getMore`; its effective timeout mode is always iteration.

A cursor with a positive limit requests only the remaining document count on `getMore`. If the
server cursor is still live when that limit is reached, the following `next()` closes it before
returning nil. A zero-id empty initial batch starts closed; a zero-id batch containing documents
closes when its last document is returned.

`cursor:iter() -> iterator`

The returned closure calls `cursor:next()` and can be used as `for document in cursor:iter() do`.
Generic Lua iteration stops when its first value is nil.
`iter()` cannot expose an operational error to a generic Lua `for` loop. Use an explicit
`next()` loop when failures must be handled, and do not use `iter()` to poll a tailable cursor
because an empty live batch ends the loop even though the cursor remains open.

`cursor:is_closed() -> boolean`

This reports local lifecycle state without performing I/O. Normal exhaustion, explicit close,
client close, and most non-timeout `getMore` failures close the cursor. A CSOT timeout does not;
cancellation of an await-data read and a server error on a pinned cursor can also leave the
cursor open. After any `nil, err`, check this method and close the cursor if it is still open.
Calling `next()` after ordinary exhaustion returns nil without error. Calling it after the
owning client closes returns a `CLIENT` error.

`cursor:close([options]) -> boolean | nil, err`

Closing a live server cursor sends `killCursors` on its selected server and pinned connection,
then releases the pin and implicit session context. A zero-id cursor or a cursor whose client is
already closed closes locally. `options`, when present, is a table whose `deadline` and
`cancellation` bound cleanup. A cursor created under CSOT uses a fresh copy of its operation
timeout for close, and `timeout_ms` can override that cleanup budget; an earlier iteration
timeout therefore does not prevent an explicit close attempt.

The first close returns true when cleanup succeeds or when a failed pinned connection already
made `killCursors` unnecessary. A reportable cleanup-command failure returns `nil, err`, but the
cursor is still locally closed and its owned resources are released.
`close()` returns false when the cursor was already closed and no failed pin remains.

### Change-stream iteration

`change_stream:next() -> document | nil, err`

This blocking form waits across empty live batches until it can return a change event, terminal
exhaustion, or an operational error. It may transparently recreate a resumable stream once
before returning. Every returned change event must have a non-nil `_id`; if it does not, the
driver closes the cursor and returns a `CLIENT` error because future resume would be unsafe.

`change_stream:try_next() -> document | nil, err`

This cooperative form consumes a buffered event immediately or advances the underlying cursor
once. `try_next()` performs at most one cursor advance when no resume is required. An empty live
batch returns nil without an error while the stream remains open, allowing the application to
run other coroutine work before polling again. If an iteration has to resume, it can also close
the old cursor, establish the replacement, and advance that replacement once.

`change_stream:iter() -> iterator`

The returned closure calls `change_stream:next()`. It has the same generic-`for` error limitation
as `cursor:iter()` and is appropriate only when stopping silently on a terminal nil is acceptable.

`change_stream:is_closed() -> boolean`

This reports the state of the owned cursor. A nil cooperative poll does not close a live stream.
After an error, the application should inspect this value and explicitly close any stream that
remains open.

`change_stream:resume_token() -> document | nil`

This returns the immutable token the next transparent resume would use, or nil when no token is
available. The initial `resume_after` or `start_after` value is cached immediately. After an
event, the driver normally caches its `_id`. A post-batch resume token replaces the document
token after the last document in a batch and also advances the token after an empty live batch.
When establishment has no token or buffered event, a qualifying server `operationTime` becomes
the resume position but is not returned by `resume_token()`.

`start_after` remains the resume position until the first change event.
After the first event, resumptions use `resume_after`. Recreated streams preserve the original
scope, user pipeline, aggregate options, read preference, and explicit session while replacing
all three position options with exactly the selected cached token or operation time.

### Change-stream resumability and timeouts

On supported MongoDB versions, a wrapped network error, cursor-not-found code 43, or server error
with the `ResumableChangeStreamError` label is resumable. The driver closes the old cursor,
suppresses any cleanup error, recreates from the best saved position, and reads from the
replacement. Each resumable read failure receives one immediate recreation attempt. A failed
recreation and every non-resumable error are returned directly.
A second failure after an immediate recreation is returned without another resume. A recreation
scheduled by a prior CSOT timeout happens before the new read; a resumable failure from that new
read can still receive its one immediate recreation.

`timeout_ms` separately bounds establishment and each call to `next()` or `try_next()`. Each
iteration receives a fresh budget.
Within it, one iteration timeout budget covers the read and any resume work.
`max_await_time_ms` must be lower than a positive timeout and is reduced to the remaining budget
before `getMore`. Change streams reject an explicit `timeout_mode` because this per-iteration
behavior is fixed.

A CSOT timeout leaves the stream open and schedules recreation for the next iteration. The
timeout is returned immediately; the driver does not spend a second budget resuming within the
same call. The next `next()` or `try_next()` receives a fresh budget, first recreates from the
saved position, and then continues reading.

`change_stream:close([options]) -> boolean | nil, err`

This delegates to the owned cursor and has the same cleanup options and return contract.
Applications should close a stream when they stop before exhaustion. Repeated close returns
false after the owned cursor and any connection pin are fully released.

## Session and transaction APIs

`client:start_session` returns an immutable explicit session. A session belongs to exactly one
client: passing it to another client's operation returns a `CLIENT` error. Sessions are not
safe for concurrent use or for reuse in another process; an application must serialize all
operations on a session. Pass the session as the `session` option to every operation that should
participate in its causal history or active transaction. An operation that omits it is outside
the transaction, including an operation run from a `with_transaction` callback.

### Session construction and causal state

`client:start_session([options]) -> session | nil, err` accepts these options:

| Option | Default | Contract |
|---|---|---|
| `causal_consistency` | true unless `snapshot` is true | Boolean controlling causal read concern. |
| `snapshot` | false | Boolean enabling snapshot reads; requires MongoDB 5.0 or newer. |
| `snapshot_time` | unset | BSON timestamp used as the snapshot's `atClusterTime`; requires `snapshot = true`. |
| `default_transaction_options` | client transaction defaults | Table containing the transaction options described below. |
| `timeout_ms` | client `timeout_ms` | Non-negative integer default for session transaction methods; zero is unbounded. |

Causal consistency defaults to true except for snapshot sessions. Snapshot mode rejects
`causal_consistency = true`, sends snapshot read concern on every session operation, and cannot
be used against a server older than MongoDB 5.0. Without an explicit `snapshot_time`, the first
snapshot read captures the server's timestamp and later operations reuse it. Snapshot sessions
cannot start transactions. Unknown options and invalid option types raise; a closed client, a
deployment without session support, or failure to allocate a session identifier returns
`nil, err`.

`session:get_lsid() -> document`

Returns the immutable logical-session-id BSON document assigned for this session's lifetime.

`session:get_operation_time() -> timestamp | nil`

Returns the greatest BSON operation time observed by this session, or nil before one is known.

`session:advance_operation_time(timestamp) -> true | nil, err`

Advances operation time only when `timestamp` is later than the stored value. A non-timestamp
argument raises. An ended session returns `nil, err`.

`session:get_cluster_time() -> document | nil`

Returns the greatest signed cluster-time document observed by this session, or nil before one
is known.

`session:advance_cluster_time(cluster_time) -> true | nil, err`

Advances cluster time only when the document's `clusterTime` BSON timestamp is later than the
stored value. A value without that timestamp raises. An ended session returns `nil, err`.

`session:get_snapshot_time() -> timestamp | nil`

Returns the explicit or first captured snapshot timestamp. It returns nil for an ordinary
session and for a snapshot session that has not captured a time. Applications cannot mutate
the stored value through the session.

### Explicit transaction control

`session:is_in_transaction() -> boolean`

Returns true while the transaction is starting or in progress. It returns false before a
transaction starts and after commit or abort, without performing I/O.

`session:start_transaction([options]) -> true | nil, err`

Starts a new local transaction and increments its transaction number. Options are
`read_concern` (BSON document), `read_preference` (table or BSON document), `write_concern`
(BSON document), and `max_commit_time_ms`. Transaction options resolve from client defaults,
then session defaults, then explicit start options. The first operation sent with the session
starts the server transaction and applies its read concern; all transaction operations use the
same transaction number. Transaction read preference must resolve to primary. An active
transaction, snapshot session, or unacknowledged write concern returns `nil, err`; unknown
options and invalid value types raise.

`session:commit_transaction([options]) -> document | true | nil, err`

Commits an active transaction. The only method option is `timeout_ms`; the transaction's
`max_commit_time_ms` and write concern come from its start options. A transaction with no
server operation commits locally and returns true. Otherwise success returns the server BSON
response. Repeated commit after a non-empty commit sends `commitTransaction` again with retry
write-concern rules; repeated commit after an empty transaction returns true locally.

The driver retries one failed commit command for a network or timeout error, a
`RetryableWriteError`, or a retryable authentication handshake failure, independently of the
client's `retry_writes` setting. It adds the required `RetryableWriteError` and
`UnknownTransactionCommitResult` labels before returning a qualifying failure. Calling commit
without a transaction or after abort returns `nil, err`. Unknown options and invalid
`timeout_ms` values raise.

`session:abort_transaction([options]) -> true | nil, err`

Aborts an active transaction. The only option is `timeout_ms`. An empty transaction is aborted
locally. For a transaction that reached the server, the driver makes the abort command and one
retry for a qualifying retryable failure, then deliberately ignores command errors because the
application cannot usefully act on them. It releases the transaction pin and returns true.
Calling abort without a transaction, twice, or after commit returns `nil, err`; unknown options
and invalid `timeout_ms` values raise.

After commit or abort, the next ordinary operation on the session resets its completed local
transaction state. A new `start_transaction` call may also begin immediately. The core API does
not retry the transaction body: applications using it own all error handling and retry policy.

### Callback transaction control

`session:with_transaction(callback [, options]) -> value | nil, err`

Starts a transaction, calls `callback(session)`, and commits if the callback leaves the
transaction active. Its options are the four `start_transaction` options plus `timeout_ms`.
The callback returns one application value on success or `nil, structured_error` on an
operational failure; the successful value is returned after commit. A non-structured second
error value raises. If the callback raises a structured error, it is handled as an operational
failure; any other raised value is re-raised after a best-effort abort. A callback that commits
or aborts directly ends the helper without another transaction-control command.

The helper aborts after a callback error. A `TransientTransactionError` retries the entire
transaction with jittered exponential backoff. The callback may run more than once and must
therefore be safe to repeat, including any effects outside MongoDB. An
`UnknownTransactionCommitResult` retries commit without rerunning the callback; a
`TransientTransactionError` from commit retries the whole transaction. Other errors return
immediately. Callback code must propagate command failures instead of swallowing them, because
the server may already have aborted the transaction. Use explicit transaction control when the
application needs a different recovery policy.

Without an effective `timeout_ms`, callback and commit retries share one 120-second retry
window. With `timeout_ms`, one absolute CSOT deadline covers the helper, its callback operations
that use this session, commit attempts, and retry decisions. Operations using the session inside
the callback cannot override `timeout_ms`; attempting to do so returns a `CLIENT` error.
Operations that omit the session receive neither its transaction nor its remaining timeout.
When a callback failure requires abort after that deadline expires, cleanup receives one fresh
session timeout budget, so total wall time can exceed the original deadline. If retry time is
exhausted, the helper returns a timeout error that retains the last error as its cause and
copies its labels.

### Pinning and cleanup

The driver owns transaction pins; applications do not select, release, or transfer them. On a
sharded deployment, the first transaction operation pins the session to one mongos for later
commands. On a load-balanced deployment, it pins one physical connection. A cursor opened in
the transaction borrows that session pin. Closing a cursor does not release a session's
transaction pin. Abort, the error transitions required by the transaction specification,
session end, and client close release it; a retry can then select and pin a replacement.

`session:is_ended() -> boolean`

Reports local lifecycle state without I/O.

`session:end_session() -> true`

Calling `end_session()` aborts an active transaction on a best-effort basis, releases any
transaction pin, and returns a clean unexpired server session to the client's pool. The client
also ends every session still registered when it closes and sends a best-effort `endSessions`
command before shutting down its executor. A repeated `end_session()` call also returns true.
After end, operations and state-changing session methods return a `CLIENT` error. Applications
should end explicit sessions promptly even though client close is a final safety net.

## Bulk, index-model, and GridFS APIs

### Collection bulk models

`mongodb.bulk` is available through `require("mongodb.bulk")` and as `mongodb.bulk`. Its
constructors return immutable models accepted only by `collection:bulk_write`:

- `mongodb.bulk.insert_one(document) -> model`
- `mongodb.bulk.update_one(filter, update [, options]) -> model`
- `mongodb.bulk.update_many(filter, update [, options]) -> model`
- `mongodb.bulk.replace_one(filter, replacement [, options]) -> model`
- `mongodb.bulk.delete_one(filter [, options]) -> model`
- `mongodb.bulk.delete_many(filter [, options]) -> model`

Documents, filters, replacements, and modifier updates are BSON documents. An update can also
be a non-empty BSON array of pipeline-stage documents. Modifier documents must begin with `$`;
replacements must not. Update-model options are `array_filters` (BSON array of documents),
`collation` and `sort` (BSON documents), `hint` (index name or BSON document), and `upsert`
(boolean). `update_many` rejects `sort`. Replacement models accept the same options except
`array_filters`; delete models accept only `collation` and `hint`. Unknown model options,
malformed BSON shapes, and invalid value types raise.

A model exposes only its immutable `kind`: `insert`, `update`, or `delete`. The constructor does
not mutate its BSON arguments. Immediately before execution, an insert model without `_id` is
copied with a generated ObjectId; entropy failure returns from the bulk operation as
`nil, err`.

`collection:bulk_write(models [, options]) -> result | nil, err`

The execution contract and command options are introduced in the
[collection reference](#write-results). `models` is a non-empty dense Lua array. The driver
splits it by server count and message-size limits. Ordered mode preserves model order and stops
after the first write error. Unordered mode may regroup operations by command kind, continues
after individual write failures, and maps every result and error back to the original model
position. Model positions and result maps are one-based.

An acknowledged immutable result exposes `acknowledged`, `inserted_count`, `matched_count`,
`modified_count`, `deleted_count`, `upserted_count`, and the immutable `upserted_ids` map.
`insert_many` additionally exposes `inserted_ids`. Unacknowledged results expose only
`acknowledged = false`; no count or identifier is inferred without a server response.

An individual write, concern, or later command failure returns a `WRITE` error. Its immutable
`details` has these fields:

| Field | Collection bulk contract |
|---|---|
| `partial_result` | Counts confirmed by acknowledged responses before failure, including zero counts. |
| `processed_count` | Number of original models attempted through the stopping point. |
| `unprocessed_count` | Models not attempted after that point. |
| `write_errors` | Array ordered by original one-based model position. |
| `write_concern_errors` | Array of observed write-concern failures. |
| `response` | Server response carried by an underlying command failure, when available. |
| `responses` | Acknowledged batch responses received before failure. |

Each write error contains `index`, `code`, optional `code_name`, `message`, and optional
`details` copied from server `errInfo`. A concern error has the same fields except `index`.
The top-level error uses the first individual or concern failure for its code and message,
retains a command failure as `cause`, and preserves labels.

### Client bulk models and results

`mongodb.client_bulk` is available through `require("mongodb.client_bulk")` and as
`mongodb.client_bulk`. Its models are distinct from collection bulk models and include a target
namespace in `database.collection` form:

- `mongodb.client_bulk.insert_one(namespace, document) -> model`
- `mongodb.client_bulk.update_one(namespace, filter, update [, options]) -> model`
- `mongodb.client_bulk.update_many(namespace, filter, update [, options]) -> model`
- `mongodb.client_bulk.replace_one(namespace, filter, replacement [, options]) -> model`
- `mongodb.client_bulk.delete_one(namespace, filter [, options]) -> model`
- `mongodb.client_bulk.delete_many(namespace, filter [, options]) -> model`

The namespace must be valid UTF-8 with a non-empty database and collection separated by a dot.
Document and option validation matches the corresponding `mongodb.bulk` constructors. Models
are immutable and expose only `kind`.

`client:bulk_write(models [, options]) -> result | nil, err`

This method requires MongoDB 8.0 or newer and accepts a non-empty dense array of client-bulk
models. Options are `bypass_document_validation`, `ordered` (default true), and
`verbose_results` (booleans); `let` (BSON document); `comment`; an operation-level
`write_concern`; and `session`, `cancellation`, `deadline`, and `timeout_ms`. The operation write
concern overrides the client default, but cannot be specified after a transaction starts.
Unacknowledged execution requires `ordered = false`, forbids an explicit session and verbose
results, and returns only `acknowledged = false`.

The entire client bulk operation shares one CSOT deadline across batch creation, every server
batch, one retry for each eligible batch containing no multi-document write, result-cursor
`getMore`, and checked cursor cleanup. Multi-document writes and transaction batches are not
retried. The result cursor is internal and is exhausted before a success value becomes visible.

An acknowledged summary result is immutable and exposes `acknowledged`,
`has_verbose_results = false`, and the five counts `inserted_count`, `matched_count`,
`modified_count`, `deleted_count`, and `upserted_count`. `has_verbose_results` is false for
summary results. With `verbose_results = true`, it is true and the result also exposes immutable
maps keyed by original one-based model position:

| Map | Per-model result |
|---|---|
| `insert_results` | `acknowledged` and `inserted_id`. |
| `update_results` | `acknowledged`, `matched_count`, `modified_count`, and optional `upserted_id`. |
| `delete_results` | `acknowledged` and `deleted_count`. |

An individual or concern failure returns a `WRITE` error. `details.write_errors` is ordered by
original model position; each item exposes `index`, `code`, optional `code_name`, `message`,
optional `details` from `errInfo`, and the failed BSON `operation`. The
`details.write_concern_errors` items omit `index` and `operation`. Ordered execution reports its
first individual failure; unordered execution reports every observed failure.
`details.partial_result` is present only after at least one model is known to have succeeded and
uses the same summary or verbose shape. It is absent when the first ordered model or every
unordered model fails. A result-cursor command failure can additionally expose
`details.cleanup_error`; an available underlying response is retained as `details.response`.

### Index models

`mongodb.index_model(keys [, options]) -> index_model`

`keys` is a non-empty ordered BSON document. Each direction is 1, -1, `2d`, `2dsphere`,
`geoHaystack`, `hashed`, or `text`. Options have the exact names and value shapes listed under
[`collection:create_index`](#standard-indexes). When `name` is omitted, the driver joins each
key and direction in order, such as `kind_1_created_at_-1`.

Index models expose immutable `keys`, `name`, and `document` properties. `document` is the
complete ordered create-index model containing the key, resolved name, and translated MongoDB
option names. Invalid key directions, option names, or option values raise. A model can be
passed to `create_index`, `create_indexes`, and `drop_index`; index options cannot be overlaid
when an existing model is supplied.

### GridFS buckets and ownership

`mongodb.gridfs_bucket(database [, options]) -> bucket | nil, err`

The same constructor is available as `database:gridfs_bucket([options])`. Options are
`bucket_name` (`fs` by default), `chunk_size_bytes` (261120 by default and at most signed
32-bit), `disable_md5` (false), `read_concern`, `read_preference`, `write_concern`, and
`timeout_ms`. Omitted concern and timeout values inherit from the database. GridFS requires an
acknowledged write concern. Invalid normalized values return a `CONFIGURATION` error; the wrong
database type, non-table options, and unknown keys raise. The `disable_md5` option records the
legacy compatibility preference; this implementation never adds the deprecated `md5` field to
new files.

The immutable bucket exposes `bucket_name`, `chunk_size_bytes`, `database`, `disable_md5`,
`read_concern`, `read_preference`, `write_concern`, and `timeout_ms`. A bucket borrows its
database and client lifetime and has no `close` method. Upload and download streams must finish
before their client closes; they do not own the bucket or client.

### GridFS uploads

- `bucket:open_upload_stream(filename [, options]) -> upload_stream | nil, err` creates a stream
  with a generated ObjectId and performs no database I/O.
- `bucket:open_upload_stream_with_id(identifier, filename [, options]) -> upload_stream | nil, err`
  uses the non-nil caller value as `_id` and also performs no database I/O.
- `bucket:upload_from_stream(filename, source [, options]) -> id | nil, err` owns and closes its
  temporary upload stream and returns the generated identifier.
- `bucket:upload_from_stream_with_id(identifier, filename, source [, options]) -> true | nil, err`
  does the same with a caller-provided non-nil identifier.

Filenames are UTF-8 strings. Stream options are `chunk_size_bytes` and `metadata` (BSON
document). The convenience methods additionally accept `timeout_ms`. Their `source` is either a
byte string or a readable table/userdata with `read(size)`. A readable source signals EOF with
nil or an empty string and may return `nil, err`; invalid arguments raise.

An upload stream is immutable and exposes `id`, `filename`, `chunk_size_bytes`, `length`,
`upload_date`, `closed`, and `aborted`. `upload_date` is nil until a successful close.

`upload_stream:write(data) -> true | nil, err`

Buffers byte-string data and inserts each complete chunk. The required GridFS indexes are
checked lazily on the first upload when the files collection is empty: `{filename: 1,
uploadDate: 1}` on files and the unique `{files_id: 1, n: 1}` on chunks. Later uploads reuse the
bucket's successful check. An index, chunk, or metadata-write failure returns `nil, err` and
leaves the stream open. A failed upload does not automatically remove chunks already written;
the application must call `abort()` when cleanup is required.

`upload_stream:close() -> true | nil, err`

Flushes the final partial chunk, ensures the indexes, and then inserts the files document. The
files document is inserted only after every chunk is stored, so incomplete uploads are not
published as complete files. Success sets `closed` and `upload_date` and returns true. Repeated
close after success also returns true. A close failure leaves the stream open; close after abort
returns a `CLIENT` error.

`upload_stream:abort() -> true | nil, err`

Marks the stream aborted and closed, discards buffered bytes, deletes stored chunks, then
deletes any files document. `abort()` is terminal even when cleanup fails. A cleanup failure is
returned again by a repeated abort without another attempt; repeated abort after success and
close after abort return `CLIENT` errors.

`upload_from_stream*` applies one effective `timeout_ms` deadline to source reads, index work,
chunk writes, metadata insertion, and source-failure cleanup. It aborts after a source read
failure and preserves that original failure even if cleanup also fails. The driver never closes
a caller-provided source. A manually controlled upload stream has no reserved lifetime
deadline: each blocking chunk or close operation independently inherits the bucket's timeout.

### GridFS downloads

- `bucket:open_download_stream(identifier [, options]) -> download_stream | nil, err` opens the
  files document for a non-nil id.
- `bucket:open_download_stream_by_name(filename [, options]) -> download_stream | nil, err`
  selects one filename revision. `revision` defaults to -1, the newest file. Non-negative
  revisions count from the oldest file starting at zero. A negative revision counts backward
  from the newest file: -1 is newest, -2 is the previous version.
- `bucket:download_to_stream(identifier, destination [, options]) -> true | nil, err`
- `bucket:download_to_stream_by_name(filename, destination [, options]) -> true | nil, err`
  accept a table/userdata with `write(data)` and own the temporary download stream they open.

Download options contain `timeout_ms`; by-name forms also accept a signed 32-bit `revision`.
The immutable stream exposes `id`, `filename`, `length`, `chunk_size_bytes`, `upload_date`,
`metadata`, and `closed`. Opening validates required files-document metadata. Missing ids and
filenames return a GridFS `file_not_found` error; a filename that exists without the selected
revision returns `revision_not_found`.

`download_stream:read([size]) -> string | nil, err`

With no size or -1, reads all bytes from the current position; otherwise `size` is a
non-negative integer. EOF and a zero-byte request return an empty string. Chunks are loaded in
ascending `n` order and must have the exact expected length. A missing, out-of-order, or invalid
chunk closes the internal cursor and records a sticky `corrupt_file` error returned by later
reads and seeks.

`download_stream:tell() -> integer`

Returns the current zero-based byte position without I/O, including a position beyond EOF.

`download_stream:seek([whence [, offset]]) -> integer | nil, err`

`whence` defaults to `cur` and is `set`, `cur`, or `end`; integer `offset` defaults to zero.
Seeking closes the current chunk cursor, clears buffered chunk data, and returns the new
position. A negative result raises. Seeking beyond the end is allowed and a following read
returns an empty string.

`download_stream:close() -> true | nil, err`

Closes the internal chunk cursor, clears buffered data, and marks the stream closed. Repeated
close returns true. Reads and seeks after close return a `CLIENT` error. The opening timeout and
every download-stream read, seek, and close share one deadline captured when the stream opens;
the budget is not refreshed between calls.

The `download_to_stream*` methods use one deadline for lookup, all reads and destination writes,
and internal close. They always attempt to close their download stream. The first read or
destination-write failure takes precedence over a later close failure; a close error is returned
when copying otherwise succeeds. The driver never closes a caller-provided destination.

### GridFS file management

`bucket:delete(identifier [, options]) -> true | nil, err`

Deletes the files document first and then all matching chunks under one deadline. Deleting a
missing id still removes orphan chunks before returning `file_not_found`.

`bucket:delete_by_name(filename [, options]) -> true | nil, err`

Collects every matching id, deletes every files document for the name, and then deletes their
chunks under one deadline. No matching filename returns `file_not_found`.

`bucket:find([filter [, options]]) -> cursor | nil, err`

Queries the files collection. `filter` defaults to an empty BSON document. Options are
`allow_disk_use` and `no_cursor_timeout` (booleans); `batch_size`, `limit`, `max_time_ms`, and
`skip` (validated as by `collection:find`); `sort` (BSON document); and `timeout_ms`. The cursor
uses the bucket read concern and preference and follows the ordinary cursor lifecycle contract.

`bucket:rename(identifier, new_filename [, options]) -> true | nil, err`

Renames one files document. A missing id returns `file_not_found`.

`bucket:rename_by_name(filename, new_filename [, options]) -> true | nil, err`

Renames every files document for the original filename. No match returns `file_not_found`.

`bucket:drop([options]) -> true | nil, err`

Drops the files collection and then the chunks collection. Delete, rename, and drop options
contain only `timeout_ms`. GridFS multi-command methods do not roll back an earlier successful
command when a later command fails.

GridFS-specific operational errors use the structured `CLIENT` category and place a discriminator
in details: `details.gridfs` is `file_not_found`, `revision_not_found`, or `corrupt_file`.
Additional details identify the id, filename, revision, metadata field, or corrupt chunk when
available. Nil identifiers, invalid filenames, stream values, and read/seek arguments raise as
described above. Management and download methods also reject unknown options.

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

The release rock and default Copas runtime are verified on Linux and macOS. Windows and other
untested operating systems are not supported. A custom runtime adapter is an extension point,
not a platform support claim. Supporting another operating system requires recurring package,
runtime, and network verification in addition to an adapter implementation.

### Runtime façade and contract helpers

The advanced `mongodb.runtime` façade has these signatures:

- `mongodb.runtime.copas([options]) -> runtime` constructs and validates the default adapter.
- `mongodb.runtime.validate(runtime) -> runtime` returns the same table after structural
  validation; a missing capability or malformed optional provider raises.
- `mongodb.runtime.required_capabilities() -> paths` returns a new array containing the 25
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
| `output.write` | `runtime.output:write(destination, value) -> true`; destination is `stdout` or `stderr`, and operational failure returns `nil, err`. |
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
runtime may also expose `dns.resolve_host` and `dns.resolve_address` for GSSAPI service-host
canonicalization. Adapters must provide both functions or neither. `resolve_host(name [,
deadline [, cancellation]])` returns `{ canonical_name, address }`, and
`resolve_address(address [, deadline [, cancellation]])` returns a hostname. Operational
failures return `nil, err`.

GSSAPI authentication uses an optional `runtime.gssapi` provider. Its
`create_context(options [, deadline [, cancellation]])` method receives `service_principal`,
`username`, and an optional `password`, then returns a context or `nil, err`. A context supplies
`step(challenge [, deadline [, cancellation]]) -> { token, complete }`,
`security_layer(challenge, username [, deadline [, cancellation]]) -> token`, and
`close() -> true | nil, err`. Tokens are raw byte strings. The driver closes every created
context, including after failed commands, provider failures, timeouts, cancellation, and raised
programmer errors.

A provider may expose `capabilities() -> table` with `default_credentials`,
`password_credentials`, and `platform` fields. The packaged provider always reports them and
rejects a credential mode the system GSSAPI library does not support. Custom providers may omit
capability reporting and retain the existing context contract.

A runtime may expose `compression`, keyed by compressor name. Each compression provider has a
matching `name`, a unique integer `compressor_id` from 1 through 255, and `compress` and
`decompress` functions. `mongodb.runtime.validate` checks the required function paths, optional
metadata type, GSSAPI DNS pair, and compression-provider shape. GSSAPI provider validation is
limited to its `create_context` method and optional `capabilities` method; adapter authors remain
responsible for the operation semantics above.

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
- `mongodb.runtime.gssapi.new(runtime, binding) -> gssapi_provider | nil` adapts a supported
  low-level system binding. `mongodb.runtime.gssapi.load(runtime [, loader])` lazily loads the
  packaged binding and returns nil when the platform library is absent or unsupported. Binding
  failures become fixed, credential-free authentication errors.
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
| `crypto`, `entropy`, `dns`, `file`, `gssapi`, `http`, `socket`, `tls` | Complete capability or provider overrides. |
| `dns_nameservers` | Adapter-local nameserver list for the default DNS provider. |
| `dns_query_timeout` | Positive per-nameserver DNS query bound in seconds. |
| `dns_resolver` | LuaSocket-compatible resolver used for forward and reverse host lookups. |
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
