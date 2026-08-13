# Changelog

All notable changes to this project are documented in this file.

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
