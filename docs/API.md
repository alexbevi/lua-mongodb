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

## Top-level exports

`require("mongodb")` is the preferred entry point. Its public exports are `_VERSION`, `bson`,
`bulk`, `client`, `client_bulk`, `error`, `gridfs_bucket`, `index_model`, and `run`. The
`runtime` export is the advanced-extension façade.

The `pool`, `sdam`, `selection`, and `topology` exports are compatibility-only. They remain
present so existing consumers are not broken by this classification work, but new application
code should use client, database, collection, and runtime APIs instead. Their implementation
modules are internal and direct `require` paths are not supported entry points.

## Pre-1.0 change policy

The project remains on the `0.x` release line. Patch releases preserve the public and advanced
extension contracts. If a minor release must make an incompatible change to either supported
tier, the release notes and `CHANGELOG.md` will identify it as a breaking change and describe
the migration. Compatibility-only exports may be deprecated or removed in a minor release with
the same notice. Internal and test-only modules carry no compatibility promise.

Operational failures in the supported API return `nil, err`, where `err` is a structured
`mongodb.error` value. Programmer misuse and violated internal invariants may raise an error.
The method-level sections of the README remain the usage guide; this document defines which
entry points those contracts cover.
