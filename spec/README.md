# Verification specifications

This directory contains the project's executable tests, test-only support code,
fixtures, and checked conformance evidence. The normative MongoDB specifications
and upstream test fixtures are pinned separately under
`planning/specifications/source/`; the code here exercises the Lua driver against
those references and the project contracts recorded in `docs/ARCHITECTURE.md`.

At a high level, the directory is organized as follows:

```text
spec/
|-- unit/                    deterministic Busted specifications
|-- integration/             cross-module and loopback boundary specifications
|-- unified/                 unified-format discovery, validation, and execution
|-- corpus/                  BSON and Extended JSON corpus runners
|-- support/                 reusable Lua test runners and unified infrastructure
|   `-- mongodb/unified/     test-only unified runner modules
|-- fixtures/
|   `-- tls/                 local TLS certificates and keys for tests
|-- conformance/             specification catalogs and coverage ledger
|-- compatibility/           live MongoDB version/topology matrix and probes
|-- quality/                 coverage, complexity, and stress-test ratchets
|-- package/                 installed-rock smoke tests
|-- release/                 release scope, checklist, and publication checks
|-- v*/                      version-specific conformance projections
|-- module-classification.json
`-- sharded_environment.py
```

## Directory summaries

### `unit/`

Deterministic Lua specifications for individual modules and public behaviors.
These tests use Busted and generally isolate networking, time, scheduling, DNS,
TLS, and other runtime boundaries with injected adapters or fakes.

### `integration/`

Lua specifications that exercise behavior across module boundaries. Most use
local loopback services to verify real wire framing, runtime adapters, client
lifecycle, authentication, CRUD, retry, pooling, DNS, TLS, and change-stream
flows without requiring an externally managed MongoDB deployment.

### `unified/`

The MongoDB unified-test-format harness. Python entry points discover pinned
fixtures, maintain capability and executor registries, validate schemas, manage
test environments, and report execution; Lua entry points validate the format
and execute selected cases through the public driver.

### `corpus/`

Python-to-Lua runners for the pinned BSON, Extended JSON, and BSON binary-vector
corpora. These feed upstream cases through the public pure-Lua codec APIs.

### `support/`

Reusable Lua helpers for specifications, including configuration, CMAP, SDAM,
sessions, DNS, authentication, and resource-audit runners. This directory is on
the test module search path and is not part of the installed driver.

`support/mongodb/unified/` contains the test-only unified schema, matcher,
lifecycle, event, failpoint, driver, and runner modules. Their test-only status is
recorded beside the complete shipped-module and export inventory in
`module-classification.json`.

### `fixtures/`

Project-owned test inputs that do not come from the pinned MongoDB specification
checkout. Currently, `fixtures/tls/` contains the CA, server, client, and invalid
CA material used by local TLS tests.

### `conformance/`

Checked catalogs and ledgers that map accepted MongoDB specification documents,
prose requirements, and upstream fixture identities to their implementation and
test evidence. Companion Python generators, validators, and contract tests keep
the JSON artifacts complete and reproducible.

### `compatibility/`

The pinned live-server compatibility matrix and its validators. The Python
runner provisions one selected MongoDB version/topology row, while the Lua probes
verify standalone, replica-set, and sharded driver behavior and record environment
facts for CI evidence.

### `quality/`

Quality ratchets and their harnesses: LuaCov configuration and per-file coverage
baselines, the production Lua complexity baseline, and deterministic seeded
stress tests for timing and lifecycle boundaries.

### `package/`

Tests for the built LuaRock rather than the source checkout. They install the
package into an isolated tree, load every shipped module in a completeness pass,
and separately smoke-test the supported module paths and top-level exports.

### `release/`

Release-wide evidence and tooling. This includes the production-core scope
projection, release checklist, LuaRocks publication validation, their generated
JSON outputs, and Python contract tests.

### `v*/`

Version-specific conformance packages, currently `v04/` and `v05/`. Each package
projects the shared conformance ledger onto that release's declared boundary and
contains a scope generator/validator, its checked JSON output, and contract tests.
New release projections should follow the same `vNN/` layout.

## Root files

- `module-classification.json` assigns a stability tier to every shipped Lua
  module and top-level export, and declares test-only Lua modules that resemble
  production paths but must remain outside the rock.
- `sharded_environment.py` owns and verifies ephemeral replica-set-backed sharded
  MongoDB deployments used by live unified and compatibility runs.

Lua specifications follow the `*_spec.lua` convention, and Python contract tests
follow `test_*.py`. Run focused checks from the repository root with
`make test-focus`; the root `Makefile` defines the broader verification gates and
the selectors available for each test area.
