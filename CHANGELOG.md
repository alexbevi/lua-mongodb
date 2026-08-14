# Changelog

All notable changes to this project are documented in this file.

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
