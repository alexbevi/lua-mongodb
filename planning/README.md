# Executable roadmap

`plan.json` is the reviewed, mostly immutable activity DAG. `progress.json` stores mutable activity status and evidence. `current_state.json` is a deterministic generated summary; never edit it by hand.

[`strategy.md`](strategy.md) documents the reproducible, specification-driven implementation and conformance method used by this project and intended for reuse by drivers in other languages.

The reference checkouts are pinned in `plan.json` and registered as Git submodules:

- `planning/pymongo` is the behavioral and structural reference.
- `planning/specifications` is the normative source and unified fixture corpus.

## Commands

```sh
python3 planning/update_plan.py check [--strict [--pushed]]
python3 planning/update_plan.py next [--track TRACK] [--json]
python3 planning/update_plan.py start ID [--track TRACK]
python3 planning/update_plan.py requeue ID --reason "..."
python3 planning/update_plan.py record-test ID --phase red --command "..." --exit-code 1 --summary "..."
python3 planning/update_plan.py record-test ID --phase green --command "..." --exit-code 0 --summary "..."
python3 planning/update_plan.py block ID --reason "..."
python3 planning/update_plan.py unblock ID
python3 planning/update_plan.py complete ID
python3 planning/update_plan.py refresh
python3 planning/update_plan.py reference-report
python3 planning/update_readme_compatibility.py [--check]
python3 spec/conformance/catalog.py [--check]
python3 spec/v04/scope.py [--check]
python3 spec/v05/scope.py [--check]
python3 spec/v06/scope.py [--check]
python3 spec/v07/scope.py [--check]
python3 spec/v08/scope.py [--check]
python3 spec/v09/scope.py [--check] [--execution-report REPORT]
python3 spec/v10/scope.py [--check] [--execution-report REPORT]
make test-focus FOCUS_UNIT=spec/unit/example_spec.lua FOCUS_LINT="src/mongodb/example.lua spec/unit/example_spec.lua"
make test-focus FOCUS_INTEGRATION=spec/integration/example_spec.lua
make test-focus FOCUS_UNIFIED='crud/tests/unified/example.json::test?1?'
make test-focus FOCUS_PYTHON=planning.tests.test_update_plan.CommitTests
make test-architecture
make test-generated
make test-complexity
```

`check` validates document shape, dependencies, cycles, generated state, and pinned references. `--strict` additionally requires exactly one commit with the completed activity's exact subject and exactly one matching `Plan-Activity` trailer, and rejects new reuse of that trailer. Published CI follow-up commits at or before the commit-policy baseline in `update_plan.py` are retained as an explicit history-only exception. `--strict --pushed` also requires the canonical commit to be reachable from a remote-tracking ref. Starting another activity applies the pushed check automatically. `refresh` only regenerates derived state; it never changes plan definitions or reference pins.

Named tracks provide an execution view over the same activity DAG. Each declaration identifies its entry, terminal, and prerequisite activity, and tracked activities name their declaration explicitly. `next --track TRACK` considers only ready members of that track; `current_state.json` exposes the same deterministic grouping as `ready_by_track`. Track selection does not change dependencies, statuses, or global plan order, and unscoped `next` retains its original first-ready behavior.

Starting an additional task requires `start ID --track TRACK`. The track must be declared and the activity must belong to it, so authorization for one goal cannot spill into unrelated ready activities. Production-core starts remain backward compatible without a track. The agent retains the user's single track authorization across its loop and reasserts that scope on each start.

`update_readme_compatibility.py` projects the conformance ledger and selected accepted-specification prose requirements into the README's driver-layer compatibility table. Machine-backed GridFS requirements are combined with their fixture cases, while prose-only suites use catalog evidence alone. Its tracked-support percentage counts passed outcomes among all support-scored outcomes and excludes `not_applicable`, `no_machine_cases`, and terminal `unsupported` outcomes. Run it whenever ledger or projected catalog statuses change; CI uses `--check` so the README cannot drift from accountable evidence.

`spec/conformance/catalog.py` inventories every document marked Accepted in the pinned specifications checkout, fingerprints its exact bytes, and assigns its suite to one explicit onion-model layer. Unlike the fixture ledger, the catalog includes prose-only specifications and test plans. Every prose-only document, plus explicitly classified normative requirements from machine-backed specifications such as GridFS, has a stable record with a roadmap owner, scope, status, runner, and exact execution evidence or reason. `not_applicable` identifies a language or API mismatch, `no_machine_cases` identifies normative prose with no portable executable assertions, and `unsupported` records a terminal project capability decision without claiming execution. None enters the tracked-support percentage. The checked artifact fails when an accepted document changes or a suite or prose requirement is added, removed, or left unclassified.

`spec/v04/scope.py` projects the exact session, transaction, Search-index, read/write-concern, SDAM, DNS, and command cases selected by the `v0-4-sharded-parity` track. It rejects missing or completed target owners, missing executor evidence, planned rows at release closure, and ratchet reductions, while distinguishing accountable exclusions owned by later load-balancing, client-bulk-write, observability, and legacy-API work. `make test-v04-scope` runs its contract and stale-generation checks. Passing `--execution-report` additionally requires every unified v0.4 target identity to have a passing row in the authoritative Full Conformance report; missing, failed, unknown-operation, and environment-skipped rows fail the gate.

`spec/v05/scope.py` projects all change-stream suite cases, retryable-read watch cases, change-stream CSOT cases, and pre/post-image event cases selected by the `v0-5-v0-7-api` track. It requires exact executor evidence for every in-floor case, records the pre-4.4 comment, MongoDB 4.2 resumable-code, and pre-7.0 error-label branches as identity-specific `ADV-011` exclusions, and rejects completed deferral owners, planned rows, and ratchet reductions. `make test-v05-scope` runs its contract and stale-generation checks. Full Conformance supplies its aggregate MongoDB 8.2 report and the focused MongoDB 8.0.16 version-branch report through repeated `--execution-report` arguments; a missing, failed, unknown-operation, or solely environment-skipped target fails the v0.5 gate.

`spec/v06/scope.py` projects the exact deprecated-count, mapReduce, database-aggregate, and tailable-cursor cases owned by the v0.6 legacy API activities. It requires exact executor and execution evidence for all 81 applicable identities, classifies 92 pre-MongoDB-7.0 identities as exact target-version exclusions, and records three command-cursor timeout identities as pinned-PyMongo behavioral exclusions. Every exclusion is identity- and reason-matched, while any ordinary deferral, incomplete passing owner, unknown operation, missing report row, or ratchet reduction fails the gate. `make test-v06-scope` runs its contract and stale-generation checks; Full Conformance validates the MongoDB 8.2 aggregate together with exact MongoDB 8.0.16 supplemental passes for the mutually exclusive deprecated-count and database-aggregate `rawData` branches.

`spec/v07/scope.py` projects the 71 exact client bulk-write identities owned by the v0.7 activities across CRUD, retryable writes, causal consistency, transactions, client-side operation timeout, Stable API, and sharded transaction pinning. Every identity must have a passing ledger record, a matching executor environment, and exact execution evidence; v0.7 has no target-version exclusions. A deferral, skipped or missing Full Conformance row, failed or unknown operation, incomplete implementation owner, or ratchet reduction fails the gate. `make test-v07-scope` runs its contract and stale-generation checks, while Linux and manual macOS Full Conformance validate the complete aggregate report.

`spec/v08/scope.py` projects all five pinned compression-option cases and eleven explicit normative OP_COMPRESSED requirements for configuration, codec identifiers, framing, response decoding, negotiation, prohibited commands, unavailable-provider warnings, and live round trips. Each record must pass with its exact runner and environment, every implementation owner must be complete, and the closure owner must be active or complete. Any deferred v0.8 evidence, missing runner, stale classification, or ratchet reduction fails `make test-v08-scope`. The compatibility probes enable zlib on every standalone, replica-set, and sharded row, so Full Conformance supplies live wire-compression evidence across the complete server/profile matrix.

`spec/v09/scope.py` projects 98 exact GridFS-related unified identities—39 GridFS fixtures, 34 retryable-read cases, and 25 timeout cases—plus fifteen explicit normative API requirements. Every record must pass with its exact runner, environment, executor, and completed v0.9 implementation owner; the closure owner may only be active or complete. Any stale or missing pinned identity, deferred v0.9 evidence, unknown unified operation, environment-only skip, missing Full Conformance row, or ratchet reduction fails `make test-v09-scope` or its `--execution-report` gate. Linux and manual macOS Full Conformance provide the authoritative complete unified reports.

`spec/v10/scope.py` projects all 40 dedicated load-balancer cases and every unified identity with a load-balanced runOn branch. It requires exact runners and completed owners for the 39 executable dedicated cases, preserves the one normative upstream skip, and requires exact Full Conformance passes for all 738 runnable cross-suite identities. The 245 optional logging, backpressure, and encryption branches must keep concrete incomplete out-of-track owners. The same gate checks the explicit OCSP and SOCKS5 unsupported decisions. `make test-v10-scope` validates the committed projection; Linux and requested macOS Full Conformance supply the authoritative aggregate execution reports.

Activity implementation follows red-green vertical slices. A `red_green` activity cannot complete without a recorded nonzero red command and successful green command. A `validation` activity requires successful green evidence. Only one activity may be `in_progress`.

`make test-focus` is the default local verification entry point. Every invocation requires an explicit selector, and multiple selectors may be combined when a slice crosses a directly coupled boundary. Full suites, coverage, stress, conformance reconciliation, platform checks, and the live compatibility matrix run in GitHub Actions after push. Run `make check` locally only for test-infrastructure changes, release preparation, cross-cutting primitives without a trustworthy focused boundary, or CI failure diagnosis.

`make test-architecture` validates the production Lua require graph and runtime isolation. It rejects cycles and reports direct OS, filesystem, socket, scheduling, TLS, native-module, or cryptography access outside `mongodb.runtime` with the exact module, file, and line. The target runs in `check-fast`; update its focused Python tests whenever the boundary policy changes.

`make test-generated` runs read-only validators for committed generated source. The Stringprep generator's `--check` mode renders the Unicode 3.2 tables in memory and fails on byte drift without creating or rewriting the output; run the generator without `--check` only when intentionally regenerating the table. The target is part of `check-fast`, while `FOCUS_PYTHON=planning.tests.test_generated_artifacts` selects its focused behavior tests.

`make test-complexity` runs Luacheck's deterministic cyclomatic-complexity report against the checked baseline. New production functions above 40 and increases to existing hotspot scores fail. A reduction also fails until `python3 tools/check_lua_complexity.py --update` records the lower score or removes the hotspot, so improvements cannot be lost. The target is part of `check-fast`, while `FOCUS_PYTHON=planning.tests.test_lua_complexity` selects the ratchet's focused behavior tests.

The unified specification runner is test-only support under `spec/support/mongodb/unified`. `spec/module-classification.json` classifies each `mongodb.unified.*` module explicitly; package and coverage contract tests reject missing classifications, test-only modules in the rockspec, and test-only modules in the production coverage baseline. Use the Make targets so `spec/support/?.lua` and `spec/support/?/init.lua` are added explicitly to the Lua test search path.

`spec/sharded_environment.py` is the shared test-only owner for an ephemeral replica-set-backed sharded deployment. It starts one config server, one shard, and one mongos; verifies exact topology, version, and host facts; and tears down every process after success or partial startup failure. Unified executor entries may select `live-sharded`; externally managed clusters must provide the same facts contract. Full Conformance installs both `mongod` and `mongos`, while driver networking remains behind the normal runtime adapter.

Use `requeue` when an in-progress activity must return to pending before implementation continues, such as when reviewed roadmap dependencies need to be inserted ahead of it. The command preserves existing evidence and records the reason; it is not a substitute for `block` when work is genuinely blocked.

Use [`prompt_goal.md`](prompt_goal.md) to launch the incremental production-core implementation.
