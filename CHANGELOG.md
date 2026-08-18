# Changelog

All notable changes to this project are documented in this file.

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
