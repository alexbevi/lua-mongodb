# PyMongo and specification mapping

The MongoDB specifications are normative. PyMongo is pinned as a mature implementation reference for boundaries, control flow, error conversion, and runner behavior. The Lua implementation deliberately does not reproduce PyMongo's class hierarchy, async-to-sync generation, Python descriptors, or C extension paths.

## Component map

| Concern | PyMongo reference | Planned Lua responsibility |
| --- | --- | --- |
| BSON | `bson/`, especially `bson/__init__.py`, `objectid.py`, `decimal128.py`, `json_util.py` | Ordered values, tagged types, exact integers/Decimal128, limits, BSON and Extended JSON codecs |
| Errors | `pymongo/errors.py` | Stable error categories, labels, server details, causal chains, and `nil, err` operational contract |
| Configuration | `pymongo/uri_parser_shared.py`, `client_options.py`, `common.py`, concerns/preferences | URI grammar, normalized options, read/write concern, read preference, Stable API |
| Wire and I/O | `pymongo/message.py`, `network_layer.py`, `synchronous/pool.py` | OP_MSG, framing, exact coroutine-aware I/O, deadlines, cancellation, connection state |
| Authentication | `pymongo/auth_shared.py`, `synchronous/auth.py`, `synchronous/auth_oidc.py` | Immutable credentials and SASL command state machines in core; crypto, DNS, HTTP, file, environment, and GSSAPI provider work behind runtime capabilities |
| SDAM and selection | `topology_description.py`, `server_description.py`, `server_selectors.py`, `synchronous/topology.py`, `monitor.py`, `server.py` | Immutable descriptions, state transitions, monitoring tasks, latency windows, selectors |
| CMAP | `synchronous/pool.py` | Checkout/check-in, generations, wait queues, handshakes, clearing, CMAP events |
| Public execution | `synchronous/mongo_client.py`, `database.py`, `collection.py`, `cursor.py`, `command_cursor.py`, `client_session.py`, `bulk.py` | Idiomatic module tables and colon methods, command lifecycle, cursors, sessions, retries, transactions, bulk batching |
| Monitoring/results | `monitoring.py`, `results.py`, `operations.py` | Command/SDAM/CMAP events, redaction, result values, operation option encoding |
| GridFS | `gridfs/` | Additional bucket/files/chunks layer |
| Unified runner | `test/unified_format.py`, `test/unified_format_shared.py`, `test/utils_spec_runner.py` | Requirements, entities, operations, matcher, outcome checks, threads/loops, fake services, capability report |

PyMongo's synchronous package is generated from its asynchronous implementation. Lua will use a single coroutine-aware implementation and explicit runtime interface, avoiding duplicated sync/async trees.

## Error boundary

PyMongo exceptions help identify error categories and server-label propagation. Lua operational APIs instead return `nil, err`. Error values retain category, message, optional MongoDB code/name, labels, retry classification, server address, topology context, and `cause`. Invalid caller types/options and impossible internal states may raise Lua errors.

## Unified test runner

The pinned specification checkout contains schema versions through 1.28 and the valid/invalid meta-tests under `source/unified-test-format/tests`. The Lua runner will first prove parsing and schema-subset behavior against those meta-tests, then build entities, execute operations, match events/results/errors, inspect outcomes, and support threads, loops, fail points, and fake KMS/OIDC services as slices require them.

A machine-readable capability map classifies every discovered `*/tests/unified/*.json::test[N]` case with extracted requirements, a content fingerprint, status, and concrete roadmap owner. Discovery failure, unknown operations, stale content, completed deferral owners, and unclassified tests fail the run. This keeps the runner useful before the entire driver surface exists without creating invisible skips.

The generated cross-format ledger in `spec/conformance/ledger.json` accounts for every JSON/YAML file and canonical JSON case under the pinned specification test trees, including BSON corpus categories and legacy URI, SDAM phase, selection, CMAP, sessions, and timeout formats. It links each stable case to the pinned specifications commit, runner, environment, milestone scope, status, evidence command, and owning activity. The checked generator rejects upstream additions, removals, edits, unknown suite owners, missing runners, and deferrals left behind after their owner completes.

## Intentional Lua adaptations

- Return small module tables and closures instead of mirroring Python inheritance.
- Model ordered BSON documents explicitly; never rely on unspecified table iteration order.
- Keep all blocking/time behavior in a runtime passed to clients and internal components.
- Use a deterministic fake runtime for unit and runner tests.
- Use LuaSec for TLS and an OpenSSL-backed Lua adapter for SHA/HMAC/PBKDF2; implement SASLprep in Lua.
- Keep core logic portable and testable without a running scheduler.
- Treat spec fixtures as data, not generated Lua source.

## GSSAPI boundary

The authentication specification defines the credential and hostname rules. The pinned PyMongo implementation supplies a behavioral reference for service-principal construction, the bounded SASL exchange, and provider cleanup. Lua keeps those rules in `mongodb.config.credentials` and `mongodb.auth.gssapi`; it does not copy PyMongo's global Kerberos-module detection or exception-based provider calls.

Hostname canonicalization uses runtime DNS operations that return a forward canonical name, the first resolved address, and an optional reverse name. Core code selects `SERVICE_HOST` or the connection host, applies the requested mode, lowercases a successful result, and falls back to the original value after an ordinary lookup failure. Cancellation and timeout remain structured control errors. This preserves the normative algorithm without importing resolver or socket modules into authentication.

An optional runtime GSSAPI provider creates one mutual-authentication context and exposes token stepping, final RFC 4752 security-layer negotiation, capability reporting, and idempotent cleanup. The core owns `$external` command construction, conversation identifiers, the ten-round limit, deadlines, cancellation, response validation, and redaction. Provider implementations own native modules, ticket caches, operating-system credentials, and KDC/TGS traffic. No GSSAPI path uses `libmongoc`.

Default-provider support is recorded per Lua version and operating system only after package installation and live authentication evidence. The project may expose provider injection more broadly, but that extension boundary does not establish support for an unverified platform.

## Pinned reference landmarks

`planning/references.json` records each pin and mapped landmark. `planning/update_plan.py check` verifies the reference locks, while `check-references` inspects the initialized checkouts and mapped paths or symbols. Neither command changes a pin.
