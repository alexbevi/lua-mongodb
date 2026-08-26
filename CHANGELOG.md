# Changelog

All notable changes to this project are documented in this file.

## [0.10.2] - 2026-08-26

GSSAPI authentication release.

### Added

- Added GSSAPI credential normalization, service-host canonicalization, and SASL authentication with default Kerberos credentials or a password when the operating-system library supports it.
- Added a packaged runtime adapter that loads the operating system's GSSAPI library on Linux and macOS without a link-time Kerberos dependency.

### Conformance

- Added exact passing evidence for eleven pinned GSSAPI configuration cases and ten normative requirements.
- Added recurring live default-credential, password, canonical-host, explicit-host, replica-set, and concurrent-context coverage on Lua 5.4 and Ubuntu 24.04.

### Release engineering

- Added GSSAPI modules to the source rock and release checks while limiting the live provider support claim to its recurring Ubuntu 24.04 and Lua 5.4 profile.

## [0.10.1] - 2026-08-25

Maintenance release.

### Fixed

- Ignored deprecated index `maxTimeMS` options when a client-side operation timeout is configured, allowing the central CSOT deadline to derive the command budget.
- Refreshed the five-byte ObjectId process value after a fork while retaining the generator's wrapping counter.

### Dependencies

- Added the pinned `getpid` 0.1.0-1 provider behind the runtime process-identity capability.

### Conformance

- Added exact passing evidence for the three deprecated-index CSOT cases and the normative ObjectId post-fork uniqueness requirement.

## [0.10.0] - 2026-08-25

Load balancing release.

### Added

- Added static load-balanced topology and server selection with single-endpoint validation, service-aware connection pools, and per-service pool generations.
- Added load-balanced command-cursor pinning, including network-error cleanup, server-error retention, explicit kill cleanup, and checkout-purpose monitoring.
- Added transaction and session connection ownership, including ordinary-error retention, transient-error unpinning, commit retry on a fresh connection, abort cleanup, repinning, and shared cursor ownership.

### Conformance

- Closed 39 of 40 dedicated load-balancer cases; the remaining upstream case retains its normative skip reason.
- Added exact passing evidence for all 738 runnable unified identities whose `runOnRequirements` include load-balanced topology.
- Classified OCSP and SOCKS5 as intentionally unsupported capabilities.

### Release engineering

- Added the generated v0.10 load-balancing projection to Full Conformance on Linux and requested macOS runs.
- Added the exact-commit v0.10 LuaRocks release checklist and publication guards.

## [0.9.0] - 2026-08-24

GridFS release.

### Added

- Added immutable configurable GridFS buckets with public upload streams, readable-source uploads, required-index management, abort, and operation-wide timeout handling.
- Added validated download streams with bounded reads, seeking, filename revisions, and destination-copy APIs that preserve caller-owned streams.
- Added deletion and renaming by id or filename, cursor-based files discovery, and whole-bucket drop with specification-defined ordering and structured errors.

### Conformance

- All 39 pinned GridFS fixtures, 34 directly coupled retryable-read cases, and 25 GridFS timeout cases have exact unified executors and passing evidence.
- Fifteen normative GridFS API requirements have exact passing runner, environment, and completed-owner evidence.

### Release engineering

- Added the generated v0.9 GridFS projection to Full Conformance, requiring all 98 machine identities to pass in the authoritative Linux and manual macOS aggregate reports.
- Added GridFS prose evidence to the generated compatibility projection and v0.9 exact-commit LuaRocks release checklist.

## [0.8.0] - 2026-08-20

Wire compression release.

### Added

- Added ordered `snappy`, `zlib`, and `zstd` compressor configuration, including zlib levels from `-1` through `9` and warnings for unavailable optional providers.
- Added pure-Lua OP_COMPRESSED framing and validation around runtime codec adapters, with compressor-specific identifiers, response-envelope decoding, and structured protocol errors for malformed messages.
- Added per-connection compressor negotiation and command execution with the specification-required uncompressed authentication, handshake, and user-management commands.

### Conformance

- All five pinned compression option cases and all eleven normative OP_COMPRESSED requirements have exact passing evidence.
- Zlib-compressed live round trips pass across the MongoDB 7.0, 8.0, and 8.2 standalone, replica-set, and sharded compatibility matrix.

### Release engineering

- Added optional Snappy and Zstandard package-test providers while retaining zlib as the required runtime codec.
- Added the generated v0.8 conformance projection to Full Conformance and the exact-commit LuaRocks release checklist.

## [0.7.0] - 2026-08-19

Client bulk write release.

### Added

- Added client-level bulk writes across multiple namespaces with insert, update, replace, and delete models.
- Added ordered and unordered execution, summary and verbose results, individual write and write-concern errors, partial results, and server result-cursor handling.
- Added command-size and batch-count splitting, sessions, transactions, retryable writes, unacknowledged writes, Stable API, sharded transaction pinning, and client-side operation timeouts.

### Conformance

- All 71 v0.7 client bulk-write cases have exact unified executors across standalone, replica-set, and sharded profiles.
- The v0.7 surface has no deferred or target-version-excluded identities within its MongoDB 8.0–8.2 feature floor.

### Release engineering

- Added the generated v0.7 conformance projection to Full Conformance and the exact-commit LuaRocks release checklist.

## [0.6.0] - 2026-08-18

Legacy APIs release.

### Added

- Added the deprecated collection `count` command with inherited concerns, read preference, retryable reads, and client-side operation timeouts.
- Added legacy collection mapReduce with inline and output modes, inherited concerns, and the specification-required single-attempt read behavior.
- Added database aggregation cursors with read/write pipeline routing, retries, timeouts, empty-batch continuation, and server-returned namespace handling.
- Added tailable and awaitData find cursors with nonblocking empty-batch polling, option validation, bounded wait budgets, and cancellation through runtime adapters.

### Conformance

- All 81 applicable v0.6 legacy API cases have exact unified executors across standalone, replica-set, authenticated, and isolated profiles.
- Ninety-two old-server-only cases are exact target-version exclusions, and three command-cursor timeout cases are explicit pinned-PyMongo behavioral exclusions.

### Release engineering

- Added the generated v0.6 conformance projection to Full Conformance and the exact-commit LuaRocks release checklist.

## [0.5.0] - 2026-08-18

Change streams release.

### Added

- Added collection, database, and cluster change streams with pipeline and cursor options, blocking and non-blocking iteration, immutable resume-token access, and one-attempt resumability.
- Added change-stream operation timeouts, comments, expanded events, namespace types, disambiguated update paths, pre/post-image events, and image configuration for collection creation and modification.
- Added collection rename support with inherited write concern and rename/invalidate change-event coverage.

### Conformance

- All 170 v0.5 cases within the MongoDB 7.0–8.2 release floor have exact unified executors across standalone, replica-set, authenticated, isolated, and sharded profiles.
- Nineteen legacy-only cases remain explicit `ADV-011` exclusions: two pre-4.4 comment branches, sixteen MongoDB 4.2 resumable-code branches, and one pre-7.0 StaleShardVersion label branch.

### Release engineering

- Added a generated v0.5 change-stream scope and exact Full Conformance evidence across the pinned MongoDB 8.2 primary and focused MongoDB 8.0.16 version branch.

## [0.4.0] - 2026-08-17

Sharded parity release.

### Added

- Added snapshot sessions with server-version enforcement, transaction rejection, snapshot read concerns, and stable snapshot-time capture and access.
- Added create, list, update, and drop Search index operations, including multi-index creation and concern omission.
- Added sharded discovery, monitoring modes and recovery, `srvMaxHosts`, command execution through mongos, transaction pinning and unpinning, and recovery-token forwarding.
- Added pool-clear handling for authentication, application, and monitor failures, including optional interruption of in-use connections.

### Conformance

- All 851 applicable v0.4 cases pass: 355 through exact unified execution and 496 through deterministic runners; 47 non-target cases retain explicit later owners or target-version exclusions.
- All 48 modern read/write-concern cases pass, and the pinned MongoDB 7.0, 8.0, and 8.2 compatibility matrix covers standalone, replica-set, and sharded deployments.

### Release engineering

- Added exact sharded Full Conformance, dual-version index evidence, and guarded v0.4.0 LuaRocks publication metadata.

## [0.3.0] - 2026-08-14

Authentication release.

### Added

- Added SASL PLAIN and MONGODB-X509 authentication with credential-safe structured failures and shared sensitive-command monitoring redaction.
- Added the pure-Lua MONGODB-AWS SASL conversation and credential resolution from environment variables, web identity, ECS/container endpoints, and EC2 metadata, including bounded runtime-adapter I/O and refreshable provider caching.
- Added MONGODB-OIDC machine and human callbacks, allowed-host enforcement, coordinated access/refresh-token caching, and built-in test, Kubernetes, Azure, and GCP providers.
- Added cached-token speculative OIDC authentication and same-connection reauthentication with one operation retry on server code 391.

### Conformance

- All six pinned OIDC no-retry read, write, speculative-authentication, and reauthentication cases pass through the deterministic public-driver loopback.
- The generated ledger classifies 5,524 normative cases: 3,671 pass, 1,851 remain assigned to named post-v1 capabilities, and two are superseded exclusions.

### Release engineering

- Updated the exact-commit release checklist, LuaRocks package, portable workflows, and public documentation for version 0.3.0.

## [0.2.0] - 2026-08-13

DNS seedlist release.

### Added

- Parsed and validated `mongodb+srv` connection strings, including `srvServiceName`, `srvMaxHosts`, implicit TLS, and the allowed `authSource`, `replicaSet`, and `loadBalanced` TXT defaults.
- Added coroutine-safe SRV and TXT resolution to the Copas runtime adapter with UDP queries, TCP fallback for truncated replies, deadline/cancellation support, and injectable deterministic DNS providers.
- Resolved and validated initial SRV seedlists before opening MongoDB sockets, including parent-domain security, explicit-option precedence, and randomized host limits.
- Polled SRV records for Unknown and Sharded topologies using bounded TTL cadence while preserving unchanged servers and safely reconciling additions and removals.

### Conformance

- All 40 pinned replica-set initial DNS seedlist fixtures and all 13 normative SRV polling prose cases pass.
- The generated ledger classifies 5,524 normative cases: 3,610 pass and 1,914 remain assigned to named post-v1 capabilities.

### Release engineering

- Publication validates the exact release commit against complete Linux, macOS, unified, coverage, packaging, and six-row compatibility evidence before creating or verifying the immutable tag and LuaRocks/GitHub artifacts.

## [0.1.0] - 2026-08-09

Initial production-core v1 release.

### Added

- Pure-Lua BSON, Extended JSON, OP_MSG, SDAM, CMAP, server selection, CRUD, collection bulk writes, administration, sessions, retries, transactions, monitoring, and client-side operation timeout.
- Coroutine-aware Copas 4.11 runtime with LuaSocket networking, LuaSec TLS, and luaossl cryptography behind runtime adapters.
- Standalone and replica-set support for MongoDB Community Server 7.0, 8.0, and 8.2 with SCRAM and TLS profiles.
- Generated conformance, compatibility, coverage, packaging, security-redaction, resource-cleanup, and release-readiness gates.

### Scope

- The release ledger classifies 5,524 normative cases: 3,559 pass and 1,965 are explicitly assigned to named post-v1 capabilities.
- Change streams, GridFS, SRV discovery, wire compression, sharded and load-balanced deployments, client bulk write, additional authentication mechanisms, observability extensions, proxy support, and client-side encryption remain post-v1.

### Release engineering

- Added a guarded GitHub Actions dry run and idempotent LuaRocks publication path with exact-commit full-conformance, immutable-tag, isolated-install, public-install, and GitHub-release verification.
