# Architecture

This document records current ownership boundaries and design decisions. It does
not record release readiness, fixture totals, or activity history. Those facts
come from the checked artifacts listed under [Verification](#verification).

## Constraints and dependency direction

The driver targets Lua 5.4 and Lua 5.5 with a 64-bit `lua_Integer`. BSON, wire
protocol, authentication, discovery, selection, pooling, sessions, retries,
transactions, and public driver behavior are implemented in Lua. The driver
does not bind or wrap `libmongoc`.

Platform work stays behind the runtime interface. The default runtime uses
Copas with LuaSocket and LuaSec. Cryptography, compression, process identity,
entropy, and GSSAPI may use native providers through that interface. A portable
core does not make an untested operating system supported. The rockspec and
README state the platforms verified by recurring package and network tests.

Dependencies follow these layers:

| Layer | Owns |
| --- | --- |
| Values | Ordered BSON values, Extended JSON, and codec limits |
| Runtime | Time, cancellation, tasks, locks, files, networking, TLS, and providers |
| Protocol | OP_MSG, compression framing, command encoding, and reply decoding |
| Topology | Server descriptions, monitoring, selection, and connection pools |
| Execution | Timeouts, sessions, retries, transactions, cursors, and events |
| API | Clients, handles, CRUD, bulk operations, administration, and GridFS |

Higher layers may depend on lower layers. Production code outside
`mongodb.runtime` may not import operating-system, filesystem, socket,
scheduling, TLS, native-module, or cryptography libraries directly.
`planning/check_architecture.py` enforces this rule and rejects require cycles.

The preferred public entry point is `require("mongodb")`.
[`spec/module-classification.json`](../spec/module-classification.json) assigns
each packaged module and top-level export to a stability tier. Packaging an
internal module does not make it public API. [`API.md`](API.md) defines the
supported entry points and pre-1.0 compatibility policy.

### Error contract

Operational failures return `nil, err`. Programmer misuse and violated internal
invariants raise. `mongodb.error` values are immutable and carry a category,
message, and optional code, code name, labels, cause, server context, timeout
status, retryability, and details.

Execution code classifies errors through fields and predicates, never by parsing
messages. Adding or removing a label returns a new error and preserves the
original cause. String conversion omits arbitrary details so server documents
and secrets are not printed by accident.

## Runtime boundary

Core modules receive one validated runtime value. The required capabilities are:

| Capability | Responsibility |
| --- | --- |
| Clock | Monotonic elapsed time, Unix wall time, and coroutine-aware sleep |
| Cancellation | Tokens with idempotent cancellation and ordered listeners |
| Tasks | Spawn, await, and cancel coroutine work |
| Locks | Non-reentrant coroutine locks |
| Process and environment | Process identity and environment lookup |
| Output and files | Log output and bounded file reads |
| DNS | SRV, TXT, forward, and reverse lookup |
| Sockets and TLS | Partial I/O, connection establishment, and TLS wrapping |
| HTTP | Bounded requests used by credential providers |
| Entropy and crypto | Random bytes, hashes, HMAC, and PBKDF2 |
| Compression | Optional whole-message Snappy, zlib, and Zstandard providers |
| GSSAPI | Optional Kerberos context creation, token steps, and cleanup |

Deadlines are absolute values from the monotonic clock. Wall time is used only
for protocol timestamps such as ObjectId generation. Runtime helpers check
cancellation before expiration and keep timeout and cancellation errors
distinct.

`mongodb.runtime.copas` is the supported default adapter. It owns Copas,
LuaSocket, LuaSec, process and entropy providers, DNS, HTTP, and optional
compression and GSSAPI loading. It polls blocking boundaries when cancellation
must remain bounded. `mongodb.runtime.fake` implements the same contract with
scripted time, tasks, sockets, DNS, crypto, and failures for deterministic
tests. A missing fake script raises because it is a malformed test, not an
operational outcome.

`mongodb.run` owns a Copas loop for a standalone program. It does not create or
close clients. Applications that already own a Copas loop construct clients
inside that loop.

### Transport, TLS, DNS, and HTTP

`mongodb.network.transport` performs exact reads and writes over partial-I/O
sockets. Every retry checks the same deadline and cancellation token. Frame
lengths are validated before allocation, and close is idempotent.

The Copas socket adapter owns non-blocking TCP integration. LuaSec wraps an
established socket, applies hostname and certificate policy, completes the TLS
handshake under the caller's deadline, and presents the same socket contract to
the transport. Core code never sees LuaSocket or LuaSec objects.

The DNS adapter reads resolver configuration through the runtime file boundary,
sends SRV and TXT queries over coroutine-aware sockets, retries truncated UDP
answers over TCP, and preserves DNS TTLs. SRV discovery validates the parent
domain before using a target. Periodic polling updates Unknown and Sharded
topologies without moving DNS work into topology state transitions.

The HTTP adapter is a small HTTP/1.1 client for AWS, Azure, GCP, and Kubernetes
credential providers. It accepts only bounded responses and supported transfer
encodings. Credential modules select destinations and security policy; the HTTP
adapter only transports requests.

## BSON and wire protocol

### BSON values

Lua tables do not stand in for BSON containers. `mongodb.bson.document` and
`mongodb.bson.array` are immutable ordered values. Documents preserve duplicate
keys. Exact int32, int64, double, and Decimal128 wrappers prevent silent numeric
coercion. Tagged values represent the remaining BSON wire types.

Encoding and decoding validate sizes, nesting, UTF-8 where BSON requires it,
array indexes, binary subtypes, and complete input consumption. Codec failures
return structured BSON errors with byte positions and details. ObjectId
generation receives entropy, wall time, and process identity from the runtime.

Extended JSON parses directly into the ordered BSON model. Canonical and relaxed
generation preserve document order and exact types. The parser applies explicit
input, string, and nesting limits rather than passing through a general JSON
library and unordered Lua tables.

### Commands and framing

The wire layer implements OP_MSG and OP_COMPRESSED. It validates flags, message
lengths, section layout, request identity, compressor identity, and uncompressed
size before returning decoded values. Handshake, authentication, and user
management commands remain uncompressed.

The command executor owns request identifiers, command encoding, exact network
exchange, response correlation, server error conversion, command monitoring,
and command logging. Sensitive commands and replies are redacted before they
reach listeners, log sinks, or string diagnostics.

## Client and operation execution

Client construction parses the URI, normalizes programmatic options, resolves
initial DNS when needed, creates credentials and metadata, and chooses the
direct or monitored execution path. Configuration is copied into immutable
driver state. Caller-owned callbacks, listeners, runtimes, and providers remain
borrowed for the client lifetime.

The executor stack has explicit responsibilities:

1. A command executor exchanges one command with one server connection.
2. A topology executor selects a server and checks out its connection when the
   monitored path is active.
3. Socket timeout handling limits individual exchanges.
4. Retry handling decides whether another command attempt is allowed.
5. Session handling adds logical session and transaction fields and advances
   causal state from replies.

A public operation validates its arguments, creates one operation timeout
context, invokes this stack, converts the response into its public result, and
releases every resource it acquired. Operation identifiers remain stable across
selection, retries, command monitoring, and logging.

### Timeouts and retries

Client-side operation timeout uses one absolute deadline across server
selection, pool checkout, command exchange, retries, cursor work, and cleanup
covered by that operation. Nested calls inherit the active context. A smaller
local timeout may narrow a budget but cannot extend it.

Retryable reads and writes use the normalized operation kind, session state,
wire version, transaction state, error labels, and server response. Retry code
does not own topology transitions or connection pinning. It asks the execution
layer for another attempt under the same operation deadline.

### Sessions and transactions

The session manager owns server-session pooling, logical session identifiers,
cluster and operation times, snapshot state, transaction numbers, and implicit
session cleanup. Sessions belong to one client and are not safe for concurrent
use.

Transaction state belongs to the session. The core API exposes explicit start,
commit, and abort operations. The callback API adds the specification retry
loop without hiding the rule that the callback may run again. Transaction pins
belong to the session, while non-transaction cursor pins belong to the cursor.
Ending a session releases its owned state and best-effort aborts active work.

### Handles and resource ownership

Client, database, and collection handles are immutable. Database and collection
handles borrow the client lifetime. A client owns its implicit sessions and
registry of open cursors and change streams. Closing the client stops topology
work and closes registered resources before returning.

Cursors own their server cursor identifier and any non-transaction connection
pin. Exhaustion or explicit close issues `killCursors` when required and releases
owned state once. Change streams own a cursor and resume state. They may recreate
that cursor after a resumable failure, but they do not own an explicit session
or the client.

GridFS buckets borrow a database and client. Upload and download streams own
their operation state. Upload close commits the files document after chunks are
written, so it is a material operation rather than passive cleanup. Caller
sources and destinations are never closed by the driver.

## Authentication

Credential normalization is separate from mechanism conversations. It resolves
the authentication source, validates mechanism properties, and creates one
credential identity that connections can share for caches and callbacks.
Secrets never enter configuration diagnostics.

The driver implements SCRAM-SHA-1, SCRAM-SHA-256, X.509, PLAIN, MONGODB-AWS,
MONGODB-OIDC, and GSSAPI. Mechanism modules receive a command interface and
runtime providers. They do not open sockets. SCRAM uses SASLprep and exact
crypto providers. AWS and OIDC fetch credentials at authentication time so
rotated workload credentials can be used by later connections. OIDC human
callbacks apply host policy before invoking application code. GSSAPI contexts
remain connection-local and always run provider cleanup.

## Topology, selection, and pooling

### SDAM and server selection

`mongodb.sdam` represents immutable server and topology descriptions and pure
hello-driven transitions. `mongodb.topology` owns monitors, current description,
SRV updates, pools, and application-error handling. Monitor connections are
separate from application connections and do not authenticate.

Server selection filters the current description by operation and read
preference, then applies latency-window and load rules. If no server is
available, the topology requests checks and waits under one deadline. Selection
does not perform socket I/O itself.

Load-balanced mode uses one permanent synthetic server description and a
service-aware pool. It does not run SDAM monitors. The service identifier from
each handshake controls pool generations and targeted clears.

### Connection pools and pinning

`mongodb.pool` owns pending, available, and checked-out connections for one
server. A FIFO wait queue enforces maximum pool size and concurrent connection
creation. Cancellation, timeout, setup failure, check-in, clear, maintenance,
and close release their capacity exactly once.

Connection establishment is injected. It returns a connected, TLS-wrapped,
handshaken, authenticated command resource or a structured error. The pool does
not implement sockets, TLS, hello, authentication, or compression negotiation.

Pool generations make old connections stale. Load-balanced pools keep a
generation per service identifier. An interrupting clear may close an in-use
physical resource, but the logical checkout remains owned until the operation
returns it. Cursor and transaction pins therefore retain one clear owner and
one release path.

## Operations and observability

CRUD, aggregation, bulk writes, administration, and GridFS build ordered BSON
commands behind the public handles. Option tables are copied and validated at
the operation boundary. Command construction does not mutate caller documents.
Multi-command operations keep original model indexes and partial results so
errors can report what completed before a failure.

Command, SDAM, heartbeat, and pool listeners receive immutable events from the
state transition that owns each event. Listener failures are isolated and may
be reported through `on_listener_error`; they cannot change driver behavior.

Structured logging uses the same command, topology, selection, heartbeat, and
pool boundaries. Configuration is normalized once per client. Redaction happens
before Extended JSON rendering and Unicode-safe truncation. A custom sink or
runtime output failure is suppressed so logging cannot change an operation's
result.

## Verification

MongoDB specifications are normative. The pinned PyMongo checkout is a behavior
reference when the specifications leave implementation details open. The
driver's evidence is stored outside this document:

| Evidence | Source |
| --- | --- |
| Accepted specification requirements | [`spec/conformance/catalog.json`](../spec/conformance/catalog.json) |
| Fixture classification and execution status | [`spec/conformance/ledger.json`](../spec/conformance/ledger.json) |
| Unified runner capabilities | [`spec/unified/capabilities.json`](../spec/unified/capabilities.json) |
| Supported environment matrix | [`spec/compatibility/matrix.json`](../spec/compatibility/matrix.json) |
| Release checks | [`spec/release/checklist.py`](../spec/release/checklist.py) |
| Test layout and generated artifacts | [`spec/README.md`](../spec/README.md) |
| Development method | [`planning/strategy.md`](../planning/strategy.md) |

Unit tests cover local values, state transitions, and API contracts. Scripted
integration tests exercise byte transfer, timing, cancellation, authentication,
and cleanup. The unified runner executes upstream fixtures through public driver
objects. Live jobs add real server versions, topologies, authentication, TLS,
packaging, and platform boundaries.

Unified-test clients use a 500 ms heartbeat interval unless a fixture supplies
`heartbeatFrequencyMS`. This test-runner-only default keeps failpoint-driven
heartbeat events within the Unified Test Format's ten-second `waitForEvent`
deadline without changing production client defaults.

Unknown unified entities, operations, arguments, events, or match operators are
failures. Unsupported cases require an explicit reason and owner. Generated
catalogs, ledgers, compatibility projections, coverage baselines, and scope
reports are validated against their inputs rather than restated here.

## Intentional exclusions

The runtime boundary is the only route to operating-system services. Core code
does not gain convenience imports for files, sockets, TLS, native crypto, or
scheduling. Network cleanup is never delegated to Lua garbage collection
because it can yield and fail.

SOCKS5 and OCSP are terminal unsupported capabilities. Unix-domain socket paths
are parsed but rejected by the current runtime. Client-side encryption,
backpressure, and OpenTelemetry remain outside the implemented feature set. The
generated compatibility table in the README and the conformance ledger are the
current source for supported and deferred behavior.
