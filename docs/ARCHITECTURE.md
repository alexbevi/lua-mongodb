# Architecture

Status: standalone-core implementation in progress. This document must be updated in the same activity that changes an architectural contract.

## Design constraints

The production implementation targets Lua 5.4 with 64-bit integers. Driver, BSON, wire protocol, SDAM, CMAP, selection, retry, and transaction behavior are pure Lua. A coroutine-aware runtime interface isolates clocks, cancellation, tasks, locks, sockets, TLS, entropy, hashing, HMAC, and PBKDF2. The supported default adapter is Copas 4.11 with LuaSocket, LuaSec, and an OpenSSL-backed crypto module.

The top-level module enforces the Lua version and integer-width constraints at load time. The LuaRocks package maps public modules from `src/mongodb`, Busted specifications live under `spec`, and Luacheck enforces Lua 5.4 plus project style. `make check` is the local and CI foundation gate; empty integration and unified phases announce the roadmap activity that will activate them.

The public entry point is `require("mongodb")`. Modules and functions use `snake_case`; stateful public values use colon methods. Operational APIs return `value` on success or `nil, err` on failure. Structured errors have stable categories, codes, labels, causal chains, and server details. Programmer misuse and broken internal invariants may raise.

### Structured error contract

`mongodb.error` constructs readonly error values rather than an exception hierarchy. Every value has a known `category` and non-empty `message`; it may also carry a numeric MongoDB `code`, `code_name`, ordered unique `labels`, a structured `cause`, server/topology context, timeout/retryability flags, and recursively readonly `details`. Diagnostic string conversion intentionally excludes details so arbitrary server documents and secrets are not rendered accidentally.

Category, label, timeout, and retryability predicates let execution layers classify failures without parsing messages. Adding or removing a label creates a new value and preserves the original causal value. Invalid constructor fields, unknown categories/options, and attempts to mutate public values are programmer errors and raise immediately. Network, protocol, server, selection, authentication, pool, BSON, and other operational failures must construct one of these values and return it as `nil, err`.

### Runtime interface

Core modules receive one validated runtime value and never import a scheduler, socket, TLS, entropy, or crypto library directly. The interface groups capabilities by responsibility:

| Capability | Required operations |
| --- | --- |
| Clock | monotonic `now`, Unix `wall_time`, and coroutine-aware `sleep` |
| Cancellation | create tokens with idempotent cancellation and ordered listeners |
| Tasks | spawn, await, and cancel coroutine work |
| Locks | create locks with explicit acquire/release transitions |
| Sockets | connect and return sockets supporting partial read/write and idempotent close |
| TLS | wrap an established socket without leaking adapter details upward |
| Entropy | return an exact number of random bytes |
| Crypto | MD5, SHA-1/SHA-256, corresponding HMAC, and PBKDF2 variants |

Deadlines are absolute values from the runtime's monotonic clock. Unix wall time is a separate capability for BSON ObjectId generation and other protocol timestamps; it is never used for elapsed-time decisions. Shared helpers derive deadlines, clamp remaining time to zero, and classify cancellation before expiration as structured operational errors. Adapter validation treats a missing function as programmer misconfiguration.

`mongodb.runtime.fake` implements the entire boundary without external dependencies. Its clock advances only under test control, tasks execute in queue order, socket reads and partial writes consume scripts, cancellation is synchronous, and TLS/entropy/crypto calls are recorded or scripted. Missing fake scripts raise because they indicate a malformed test, while scripted operational failures return `nil, err`.

`mongodb.runtime.copas` implements the scheduling boundary with Copas 4.11 futures, pauses, non-reentrant locks, and a LuaSocket TCP provider. It clamps Copas time so the driver never observes backward movement, wakes sleeping tasks on cancellation, and polls contended locks and socket waits so cancellation remains bounded. Its default `mongodb.runtime.openssl` provider supplies cryptographically secure entropy plus MD5, SHA, HMAC, and PBKDF2 through luaossl; MD5 exists only for MongoDB's legacy SCRAM-SHA-1 password transform. Its default TLS provider is the LuaSec adapter described below. Callers may inject conforming providers without changing core code.

### Exact TCP transport

`mongodb.network.transport` owns runtime-neutral connection lifecycle and exact byte transfer. It repeatedly calls the runtime socket's partial read/write operations until the requested byte count is satisfied, checking the same absolute monotonic deadline and cancellation token before every attempt. EOF, network failure, timeout, and cancellation remain distinct structured errors. Length-prefixed frame reads validate the four-byte size before allocating or reading the remainder, and close is idempotent on every path.

`mongodb.runtime.copas_socket` is the runtime-specific LuaSocket adapter. It wraps non-blocking TCP sockets with Copas, applies the remaining absolute deadline to connect/read/write waits, and bounds waits with a short poll interval when cancellation is enabled. LuaSocket error strings are translated at this boundary and never leak scheduler or socket objects into wire, topology, or command code. A loopback integration test exercises the real Copas scheduler and LuaSocket provider with deliberately split response writes.

### LuaSec TLS transport

`mongodb.runtime.luasec` converts normalized per-connection TLS policy into a LuaSec client context, while `mongodb.runtime.copas_socket` owns the runtime-specific SNI and asynchronous handshake. The core transport supplies the same absolute deadline and cancellation token used for TCP establishment; handshake polling bounds cancellation latency without resetting that deadline. A successful upgrade preserves the abstract partial read/write socket contract, so no core module imports LuaSec or sees its socket objects.

Certificate-chain and hostname verification are enabled by default. A custom CA bundle takes precedence; otherwise the adapter uses `SSL_CERT_FILE`, then common Unix CA bundle paths, with `SSL_CERT_DIR` as a directory fallback. If no trust store is available, context construction returns a structured configuration error rather than silently disabling verification. DNS connections send SNI. Hostname matching gives subject alternative names precedence over the common name, supports exact DNS names, a wildcard covering exactly one leftmost label, and canonical IPv4/IPv6 subject alternatives.

A combined client certificate/private-key PEM may be supplied with an optional decryption password. Context and handshake failures are converted to credential- and path-free structured errors. `allow_invalid_hostnames` disables only name matching; `allow_invalid_certificates` disables chain verification and therefore name matching; `insecure` disables both. LuaSec 1.3 does not expose OCSP endpoint or CRL revocation checking through this adapter, so `disable_ocsp_endpoint_check` and `disable_certificate_revocation_check` currently document intent but do not alter behavior. TLS compression and renegotiation are disabled where the linked OpenSSL supports those controls.

### BSON values and codec

`mongodb.bson` represents documents and arrays with explicit immutable containers. Documents retain insertion order and duplicate keys; indexed access returns the last matching key while `keys`, `entries`, and `iter` preserve every wire entry. Arrays are distinct from documents, and `bson.null` is distinct from absent Lua values. Constructors copy their input so later mutation cannot change an in-flight command.

The codec accepts only an ordered document at its root and encodes Lua strings as BSON strings, integral numbers as the smallest signed BSON integer, non-integral numbers as doubles, and explicit wrappers for arrays, binary data, and null. Immutable tagged values represent ObjectId, signed-millisecond UTC datetime, regular expression, timestamp, JavaScript code with optional ordered scope, Symbol, DBPointer, Undefined, MinKey, and MaxKey. Binary values retain every subtype and apply the legacy subtype-2 nested length rule. Decoding produces the same unambiguous value model. Arbitrary Lua tables are rejected because neither their intended BSON type nor their iteration order is defined.

Decoded int32, int64, and double values use explicit immutable wrappers carrying both the Lua value and original little-endian bytes. Their constructors also let callers force a numeric wire type; unwrapped Lua integers still select the smallest signed representation. This preserves small int64 values, double negative zero, and NaN payload bits across a decode/encode cycle without overloading arithmetic operators.

Decimal128 is stored as its exact 16-byte Binary Integer Decimal representation. String conversion uses decimal-digit and byte-array arithmetic in Lua, applies the 34-digit half-even context's exactness, exponent, and clamping rules, and never passes through a binary float. NaN variants and non-canonical encodings retain their input BID even when their required diagnostic string is lossy. The pinned official Decimal128 corpus is the conformance source.

ObjectId generators are stateful values constructed from an injected runtime. They obtain a five-byte generator identifier and three-byte initial counter from `runtime.entropy`, read seconds from `runtime.clock.wall_time`, and increment the 24-bit counter without importing platform time or randomness into BSON code. ObjectId, datetime, timestamp, regex, and binary values implement equality or ordering where their BSON semantics define it.

All lengths and element payloads are checked against their containing frame before reading. Invalid document, string, binary, code-scope, boolean, terminator, trailing-byte, UTF-8, and unsupported-type encodings return structured `bson` errors carrying a one-based byte offset. Codec options bound document, string, binary, and nesting sizes; the defaults are 16 MiB for each size and 100 document levels. UTF-8 validation is on by default and may be disabled explicitly for byte-preserving diagnostic work. Degenerate array keys and unordered regex flags accepted by the BSON corpus are normalized when re-encoded.

### Ordered JSON and Extended JSON

`mongodb.bson.json` parses JSON directly into the ordered BSON value model, including explicit arrays, null, and exact numeric wrappers. The recursive-descent parser validates JSON number grammar, UTF-8, escapes and surrogate pairs, trailing input, and configurable input/string/depth limits. It does not pass object pairs through an unordered Lua table.

Extended JSON conversion recognizes canonical, relaxed, and permitted degenerate representations for every BSON wire value. Known wrapper keys require their exact fields and types; unknown dollar-prefixed documents remain ordinary documents. Generation supports canonical and relaxed modes, preserves field order, uses canonical Base64/subtype encoding, and emits ISO-8601 UTC datetimes only where relaxed Extended JSON permits them.

### Unified schema validation

`mongodb.unified.schema` compiles an ordered JSON Schema document into an immutable validator. The implemented draft 2019-09 subset covers the constructs exercised by unified schema 1.28: local references, object properties and required fields, additional and pattern properties, array/property bounds, primitive types, enums, constants, the version and KMS-provider patterns, and `allOf`, `oneOf`, and `not`. Schema violations return structured `configuration` errors with both a JSONPath-like document path and a JSON Pointer schema path.

The schema gate loads only fixture envelopes in Python and performs parsing and validation in Lua. Both `valid-pass` and `valid-fail` are schema-valid—the latter are reserved for later runner failures—while every file in `invalid` must be rejected. The gate currently covers all 320 distinct JSON meta-fixtures pinned with the specification checkout; equivalent YAML copies are not counted twice.

`mongodb.unified.runner` is the execution-neutral core. Each test creates a runner with an isolated entity registry, environment facts, entity factories, per-entity-kind operation handlers, and an optional outcome reader. Entity IDs are unique and typed; missing entities, unsupported entity kinds, unsupported operations, and unknown match operators return visible `configuration` errors with document paths. This registry/dispatch boundary lets later slices connect real driver objects without teaching the runner about transports.

Run-on requirements compare numeric version components and environment topology, authentication, serverless, server-parameter, and encryption facts. Matching implements strict nested documents, root subset matching, flexible BSON numbers, exact arrays, and the unified `$$exists`, `$$type`, `$$matchesEntity`, `$$matchesHexBytes`, `$$unsetOrMatches`, `$$lte`, `$$matchAsDocument`, and `$$matchAsRoot` operators. Thread entities schedule work through the injected runtime task interface, and bounded loops record iteration and success counters as BSON entities. Unit tests use the deterministic fake runtime and fake entity/operation handlers; no runner-core test opens a network connection.

The filesystem-facing unified CLI is a Python envelope around the Lua schema/runner layers, like the BSON corpus loader. It discovers every pinned path matching `*/tests/unified/*.json`, validates exact coverage against `spec/unified/capabilities.json`, applies repeatable glob include filters, and emits a versioned JSON report. The manifest records the pinned specifications commit and assigns each fixture either `runnable` or `deferred` with an owning activity and concrete reason. Missing or stale entries, unknown statuses, empty deferral reasons, empty discovery, and runnable fixtures without an executor are hard failures.

At the foundation boundary all 483 discovered integration fixtures are deferred to the driver slice that can first execute them; client-side encryption is explicitly outside the roadmap pending a separate design. Later activities change only their newly supported manifest entries to `runnable` in the same commit as the implementation and tests. The generator's `--check` mode prevents hand-edited or stale classification drift, while normal reports retain a row for every selected fixture so exclusions cannot disappear into aggregate counts.

### Connection-string syntax

`mongodb.config.uri` owns parsing for `mongodb://` connection strings without importing networking or authentication implementations. It returns an ordered seed list whose entries distinguish hostnames, IPv4 addresses, bracketed IPv6 literals, and encoded Unix socket paths; decoded credentials and authentication database; and query pairs in source order. Hostnames are normalized to lowercase, ports are range checked, percent escapes and decoded UTF-8 are validated, and repeated query keys produce explicit warnings.

The URI parser intentionally preserves option values as decoded strings. `mongodb.config.options` maps those ordered strings and idiomatic programmatic tables into one immutable value. Programmatic settings take precedence over URI settings, but both paths use the same per-option validators for booleans, integers, strings, timeout/pool bounds, read and write concerns, read preference modes/tags/staleness, and TLS policy. Stable API is an immutable nested value, requires version `"1"`, and preserves explicitly supplied strict and deprecation flags.

URI inputs follow the normative warning policy: unknown keys, invalid non-security values, empty typed values, deprecated aliases, and duplicates are ignored or resolved with returned warnings. Programmatic input is strict, so unsupported keys and invalid values return structured `configuration` errors. Conflicting TLS options remain hard errors even in a URI. The option layer never includes supplied values in its error or warning text, which keeps certificate passwords and other secrets out of diagnostics. Advanced post-v1 URI options remain parsed as syntax but are not exposed as accepted v1 programmatic configuration.

Normalized defaults follow the specifications: 100-entry maximum and zero-entry minimum pools, two concurrent connections, 10-second connection and heartbeat intervals, 30-second server selection, 15-millisecond local threshold, primary read preference, retryable reads/writes enabled, and TLS disabled unless explicitly selected or implied by a TLS-specific setting. Downstream pool, SDAM, selection, command, retry, and timeout slices consume this value rather than re-parsing user input.

### OP_MSG framing

`mongodb.wire.op_msg` is the pure-Lua message boundary for opcode 2013. It encodes and decodes the 16-byte little-endian message header, flags, exactly one kind-0 BSON command body, and any number of uniquely named kind-1 document sequences in arbitrary section order. A deterministic request-ID generator assigns positive signed 32-bit IDs and wraps without using platform randomness; response decoding may require an exact `responseTo` match before exposing the body.

The codec rejects checksum-bearing messages because CRC-32C support is intentionally absent, rejects unknown required flag bits and response-only misuse, and ignores unknown optional high bits as the specification requires. Declared frame/section/BSON lengths are checked before slicing or decoding, and negotiated `maxMessageSizeBytes` and `maxBsonObjectSize` limits are enforced on both paths. The size-accounting API uses the same encoding preparation as the wire writer, so later bulk batching can make decisions without maintaining a second overhead formula.

### Hello and single-connection commands

`mongodb.command.executor` owns the protocol lifecycle on one exact-I/O transport connection. Its first handshake uses OP_MSG legacy `ismaster` with `helloOk: true`, unless Stable API requires modern `hello`; every hello carries the string-valued backpressure version, while only the initial hello carries client metadata. A successful legacy negotiation permanently switches later hello requests to the modern command. The executor records the reply's BSON/message/batch limits and uses the negotiated per-connection values for later encoding and framed reads.

Commands are copied from the caller's ordered BSON document, preserving the command name as the first field. Stable API fields and the `$db` global argument are appended to the copy, so caller state is never mutated. Request IDs are correlated before a reply is exposed; I/O failures, malformed frames, invalid `ok` fields, and unexpected streaming replies close the connection. An `ok: 0` reply remains a server operation failure without closing the connection and retains its numeric code, code name, labels, timeout/retryability classification, server address, and immutable BSON response details.

`mongodb.command.hello` is the immutable per-connection capability model. It validates and supplies defaults for negotiated wire, BSON, message, batch, and logical-session fields and exposes the server's basic readability/writability shape for later SDAM work. It does not select servers, pool connections, authenticate, or import runtime-specific networking; those responsibilities remain in their dedicated layers.

### SCRAM authentication

`mongodb.auth.scram` runs SCRAM-SHA-256 and SCRAM-SHA-1 over a handshaken command executor. It generates each client nonce from 32 runtime entropy bytes, escapes the raw username for the SASL name, enforces the 4,096-iteration minimum, validates that the server nonce begins with the client nonce, and compares the expected server signature in constant time. It sends `skipEmptyExchange`, supports the older third empty exchange, and caches derived client/server keys per credential identity with mechanism, salt, and iteration guards.

SCRAM-SHA-256 prepares only the password with `mongodb.auth.saslprep`; usernames remain raw as MongoDB requires. The pure-Lua implementation maps, normalizes, prohibits, and performs bidirectional checks against checked-in Unicode 3.2 tables generated by `tools/generate_stringprep_tables.py`. SCRAM-SHA-1 preserves MongoDB's legacy behavior: neither field is prepared, and the password first becomes the lowercase MD5 hex digest of `username:mongo:password` before PBKDF2-SHA-1.

SASL commands pass through the executor so normal deadlines, cancellation, and command monitoring apply. Monitoring redacts their command/reply bodies. Authentication converts server command failures, malformed payloads, nonce/signature failures, and SASLprep rejection to credential-free structured authentication errors; it never retains response payloads, passwords, salts, proofs, or signatures in those errors.

### Command monitoring

`mongodb.monitoring` publishes immutable command-started, command-succeeded, and command-failed events synchronously around application command I/O. The executor supplies a single request ID to each correlated pair, accepts an optional operation ID for multi-command work, reports the database and connection identities, and reconstructs OP_MSG document sequences as arrays in the started event. Durations come from an injected monotonic clock capability and cover the command exchange. Initial connection handshakes are excluded from command monitoring.

Listeners are copied at monitor construction and invoked in registration order. Each callback runs behind an isolated protected call, so listener failures cannot change command results or prevent later listeners from observing the event; an optional error callback receives listener failures under the same isolation rule. Event and BSON values are immutable, preventing one listener from changing what another listener observes.

Authentication commands (`authenticate`, SASL commands, nonce/user/copydb commands) and hello commands containing `speculativeAuthenticate` publish empty command and reply documents. Sensitive server failures retain only `code`, `codeName`, and `errorLabels`; network and other client-side failures remain inspectable because they do not contain server authentication payloads. Redaction occurs before listener dispatch, so no listener can opt into credential-bearing values.

### Core API and standalone lifecycle

`mongodb.client` is the public constructor boundary. It separates runtime and command-listener capabilities from programmatic driver options, parses the non-SRV URI, normalizes the combined configuration, and opens exactly one TCP seed through `mongodb.network.transport`. The resulting connection is upgraded with normalized TLS policy when requested, handshaken by `mongodb.command.executor`, and authenticated before the client is returned. A credentialed hello requests `saslSupportedMechs`; the lifecycle selects SCRAM-SHA-256 when advertised and otherwise uses the required SCRAM-SHA-1 fallback. This slice rejects multiple seeds, Unix sockets, and non-standalone hello shapes explicitly instead of silently applying incomplete topology behavior. SDAM and CMAP replace that restriction in their owning activities.

`mongodb.api` owns immutable client, database, and collection handles whose state is kept outside the visible tables. Database names reject the server-prohibited characters except for the authentication namespace `$external`; collection names reject empty components, null bytes, invalid dots, and unsupported dollar forms. Database and collection handles inherit normalized read concern, read preference, and write concern, with validated per-handle overrides. A database runs a command through the shared executor without changing the caller's ordered BSON document. Client close is idempotent and closes the executor once; all derived database handles observe the same closed state and return a structured `client` error before I/O.

The initial public lifecycle deliberately owns one authenticated connection and performs no selection, pooling, sessions, retries, or cursor management. Those layers extend this stable handle boundary in later activities. API objects depend only on configuration, runtime, transport, command, authentication, and monitoring interfaces; runtime-specific networking, TLS, and cryptography remain behind adapters.

### Single-document CRUD

`mongodb.crud` builds single-document insert and find commands from collection state without importing a runtime-specific module. Insert prepends a lazily generated ObjectId only when `_id` is absent, leaving the caller's immutable BSON document unchanged. The command carries inherited write concern plus supported insert options; `w: 0` uses OP_MSG `moreToCome`, publishes no synthetic command-success event, and returns an unacknowledged immutable result. Acknowledged replies are inspected for both `writeErrors` and `writeConcernError`; structured `write` errors retain the numeric code, labels, complete immutable response, operation index, and unparsed `errInfo`.

`find_one` accepts either an ordered filter or a scalar `_id`, maps validated options to their command names, and always appends `limit: 1` and `singleBatch: true` without a batch size. It returns the first document from `cursor.firstBatch`, returns `nil` when that batch is empty, and treats malformed cursor replies as protocol errors. Raw-data options are emitted only at the negotiated MongoDB 8.2 wire version. Tailable, awaitable, and exhaust cursor modes remain outside this slice.

### Find cursor lifecycle

`mongodb.cursor` owns immutable, coroutine-aware state for one server cursor: the current cursor identifier, buffered batch, position, retrieved count, limit, batch size, inherited comment, and command context. `collection:find` executes the initial command and validates `cursor.firstBatch`; `cursor:next` consumes buffered documents before issuing `getMore`, validates `cursor.nextBatch`, and updates the opaque 64-bit cursor identifier. A positive limit caps getMore batch size to the remaining document count. When the requested limit and initial batch size are equal, the initial command sends `batchSize = limit + 1` as required to avoid an otherwise unnecessary open cursor.

Zero-id exhaustion closes the cursor locally. Explicit close sends `killCursors` only for a live identifier and is idempotent even after a command failure. Each client keeps a weak registry of live cursors and closes them before its executor connection, so early client shutdown also performs server cleanup. Network or malformed getMore failures close local cursor state and return a structured error. Cleanup is never initiated from a garbage-collection finalizer because runtime command I/O may yield; applications stop early with `cursor:close`, while normal exhaustion and `client:close` are deterministic.

### Update, replace, and delete

`mongodb.crud` maps `update_one`, `update_many`, and `replace_one` to distinct update command models. Atomic update documents must be non-empty and begin with a `$` field; update pipelines must be non-empty BSON arrays containing only documents. Replacement documents use the inverse validation and may not begin with an atomic modifier. The model carries `multi`, `upsert`, array filters, collation, hint, and single-update sort as applicable, while command-level validation, comments, `let`, raw-data, and inherited write concern remain ordered outside the model.

`delete_one` and `delete_many` differ at the command boundary only by their normative limits of one and zero. Acknowledged mutation results expose immutable matched, modified, upserted, or deleted counts, and replacement/update upserts preserve the server-returned identifier. Unacknowledged mutations use OP_MSG `moreToCome`, expose no unavailable counts, and reject collation, array-filter, hint, or sort combinations that their negotiated wire version cannot safely execute. These command builders depend only on BSON and the executor interface; they introduce no runtime-specific networking behavior.

### Core collection read and modify operations

Collection aggregation validates an ordered BSON array of document stages and inspects only the final stage to identify `$out` or `$merge`. Read pipelines inherit read concern. Write pipelines inherit write concern, add read concern on MongoDB 4.2 and newer, ignore an initial batch size, and synthesize an exhausted cursor after an unacknowledged OP_MSG send. All other aggregate results enter the existing cursor model, so batch size, getMore comment and maximum await time, explicit kill, and client-close cleanup have one implementation.

`count_documents` builds the normative `$match`, optional `$skip` and `$limit`, and `$group` pipeline and parses its single cursor result, treating an empty batch as zero. `estimated_document_count` intentionally uses the metadata-based `count` command, while `distinct` validates and returns the server's BSON values array. These read helpers inherit read concern and use the same deadline/cancellation executor boundary as find.

The three find-and-modify helpers share one ordered `findAndModify` builder but retain update-versus-replacement validation. Delete sets `remove`; update and replacement set `update`, optional upsert, and a `new` boolean derived from the public `before`/`after` choice. Projection maps to the wire-level `fields` name. Array-filter and hint constraints are checked before unacknowledged I/O, write and write-concern errors reuse the structured write-error path, and BSON null results map to Lua `nil`.

### Collection bulk writes

`mongodb.bulk` defines immutable insert, update, replacement, and delete models shared by `collection:bulk_write`; `insert_many` builds the same insert models internally. Ordered execution preserves adjacent command-kind runs and stops on the first write error. Unordered execution groups compatible models while retaining each model's original 1-based request index for upsert identifiers and structured write errors. Every command in one call carries the same operation identifier.

Batch construction observes `maxWriteBatchSize`, then uses the command executor's OP_MSG measurement path to fit each `documents`, `updates`, or `deletes` type-1 sequence within `maxMessageSizeBytes`. Individual insert and replacement documents are also checked against `maxBsonObjectSize` where an unacknowledged server cannot report the violation. This keeps framing arithmetic in the wire layer and leaves networking, TLS, and cryptography behind their existing runtime adapters.

Acknowledged responses merge counts, upsert identifiers, write errors, write-concern errors, labels, and raw response documents into immutable results or structured partial-result errors. Unacknowledged requests use `moreToCome`; ordered multi-batch requests acknowledge intermediate batches so the driver can preserve stop-on-error semantics before sending the final unacknowledged batch.

### Database, collection, and index administration

`mongodb.admin` builds list, create, and drop commands for databases, collections, and indexes without importing any runtime provider. The public client, database, and collection handles supply their inherited concerns, negotiated wire version, executor, and shared cursor registry. Write commands apply inherited write concern and retain write-concern response details; collection and index drops treat namespace-not-found as an idempotent success.

Database enumeration wraps the command's returned array in an exhausted local command cursor. Collection and index enumeration use the server cursor namespace to construct getMore and killCursors commands, then share the existing cursor lifecycle and client-close cleanup. A listCollections comment is not repeated because the server inherits it, while listIndexes explicitly carries its comment onto getMore as required by the index-management specification.

Immutable index models retain ordered key documents, validate supported directions and option types locally, and generate deterministic key-direction names. `create_index` delegates to the same createIndexes path as multi-index creation. The boundary rejects `commit_quorum` before MongoDB 4.4 and gates internal raw-data fields on the MongoDB 8.2 wire version; all network behavior remains behind the command executor and runtime adapters.

## Planned layers

1. **Values:** ordered containers and JSON, every BSON wire value, exact numeric handling, configurable codec limits, and canonical/relaxed Extended JSON are implemented.
2. **Runtime:** coroutine scheduling, monotonic time, cancellation/deadlines, locks, exact socket I/O, TLS, and crypto capabilities.
3. **Protocol:** message framing, OP_MSG, command encoding, authentication conversations, and reply/error conversion.
4. **Topology:** immutable server/topology descriptions, SDAM transitions, monitoring, selection, connection pools, and wait queues.
5. **Execution:** command lifecycle, sessions, retries, transactions, CSOT, monitoring, and cursor cleanup.
6. **API:** clients, databases, collections, cursors, concerns, preferences, CRUD, bulk, and administration.
7. **Conformance:** unified entities, requirements, event matching, fake services, schema validation, fixture classification, and reporting.

Dependencies point downward. API objects do not call Copas, LuaSocket, LuaSec, or OpenSSL directly; they depend on runtime and protocol interfaces. The same boundary supports deterministic unit fakes.

## Command data flow

A public operation validates options, creates an operation context and deadline, selects a server, checks out a connection, applies session/transaction fields, encodes OP_MSG, performs exact deadline-aware I/O, decodes and classifies the response, emits monitoring events, updates session state, and returns a value or structured error. Cleanup is deterministic on every branch.

## Test architecture

Each activity starts with a focused red test. Unit tests use fake clocks, sockets, and topology inputs. The BSON unit gate uses Python only to load the pinned corpus envelope; all 728 canonical BSON cases, 4 degenerate BSON forms, 75 decode errors, 1,080 Extended JSON representations, 180 parse errors, and canonical/relaxed generation execute against the Lua codecs. The unified gate first validates all 320 pinned JSON schema meta-fixtures through schema 1.28. Integration tests exercise supported MongoDB 7.0–8.2 deployments. The unified runner consumes the pinned specification repository and reports every fixture as passed, failed, or explicitly deferred with a reason; unknown operations are failures. Release gates include packaging smoke tests, linting, the supported Lua/runtime matrix, and strict roadmap validation.

## Intentional exclusions

Version 1 stops at standalone and replica-set production core. Post-v1 activities cover change streams, GridFS, SRV/TXT, compression, sharding, load balancing, client bulk write, additional authentication, logging, telemetry, and backpressure. Client-side field-level/queryable encryption and GSSAPI remain outside the roadmap until separately designed.
