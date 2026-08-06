# Architecture

Status: foundation implementation in progress. This document must be updated in the same activity that changes an architectural contract.

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
| Crypto | SHA-1/SHA-256, corresponding HMAC, and PBKDF2 variants |

Deadlines are absolute values from the runtime's monotonic clock. Unix wall time is a separate capability for BSON ObjectId generation and other protocol timestamps; it is never used for elapsed-time decisions. Shared helpers derive deadlines, clamp remaining time to zero, and classify cancellation before expiration as structured operational errors. Adapter validation treats a missing function as programmer misconfiguration.

`mongodb.runtime.fake` implements the entire boundary without external dependencies. Its clock advances only under test control, tasks execute in queue order, socket reads and partial writes consume scripts, cancellation is synchronous, and TLS/entropy/crypto calls are recorded or scripted. Missing fake scripts raise because they indicate a malformed test, while scripted operational failures return `nil, err`.

`mongodb.runtime.copas` implements the scheduling half of the boundary with Copas 4.11 futures, pauses, and non-reentrant locks. It clamps Copas time so the driver never observes backward movement, wakes sleeping tasks on cancellation, polls contended locks so cancellation remains bounded, and translates deadline/cancellation outcomes into structured errors. Socket, TLS, entropy, and crypto providers remain explicit unavailable capabilities until their roadmap slices; callers may inject conforming providers without changing core code.

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

Each activity starts with a focused red test. Unit tests use fake clocks, sockets, and topology inputs. The BSON unit gate uses Python only to load the pinned corpus envelope; all 728 canonical BSON cases, 4 degenerate BSON forms, 75 decode errors, 1,080 Extended JSON representations, 180 parse errors, and canonical/relaxed generation execute against the Lua codecs. Integration tests exercise supported MongoDB 7.0–8.2 deployments. The unified runner consumes the pinned specification repository and reports every fixture as passed, failed, or explicitly deferred with a reason; unknown operations are failures. Release gates include packaging smoke tests, linting, the supported Lua/runtime matrix, and strict roadmap validation.

## Intentional exclusions

Version 1 stops at standalone and replica-set production core. Post-v1 activities cover change streams, GridFS, SRV/TXT, compression, sharding, load balancing, client bulk write, additional authentication, logging, telemetry, and backpressure. Client-side field-level/queryable encryption and GSSAPI remain outside the roadmap until separately designed.
