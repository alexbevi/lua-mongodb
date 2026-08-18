# Driver implementation strategy

This document describes a repeatable method for implementing a MongoDB driver from the MongoDB specifications and a mature reference driver. The method is intended to make implementation deterministic, reproducible, measurable, and traceable. Language-specific architecture may differ, but evidence and conformance rules should remain portable.

## Definition of success

Feature parity means conformance with an explicitly declared MongoDB driver scope. It does not mean copying another driver's public API, internal class hierarchy, or implementation language conventions.

For every in-scope behavior, the project must be able to answer:

1. Which normative specification requirement defines it?
2. Which pinned upstream fixture or local contract test exercises it?
3. Which production boundary implements it?
4. Which roadmap activity and commit delivered it?
5. On which language runtimes, operating systems, server versions, topologies, and security configurations has it passed?

A feature is not complete merely because its implementation exists or a fixture is listed in an inventory. Applicable tests must execute and pass.

## Source hierarchy and pins

Use sources in this order:

1. The MongoDB specifications are normative.
2. A pinned mature driver is the behavioral reference for control flow, edge-case handling, and test-runner integration.
3. Project architecture records intentional language-specific decisions.
4. Production code and tests implement those decisions.

Both upstream repositories must be pinned to exact commits and checked in as immutable references. Normal implementation must not edit them or move their pins. A reference refresh is a separate reviewed activity that inventories upstream changes before accepting a new pin.

Reference mappings should identify specific files and symbols instead of pointing only at repository roots. Each activity should cite the narrowest relevant specification documents, test suites, and reference-driver symbols.

The reference driver is not an oracle. Driver-specific skips, workarounds, API conventions, and known bugs must be resolved against the specifications. Record intentional divergences rather than silently inheriting them.

## Architecture method

Begin by defining boundaries that permit deterministic tests:

- Ordered, lossless BSON and Extended JSON values.
- Structured operational errors distinct from programmer errors.
- Runtime interfaces for clocks, cancellation, tasks, locks, sockets, TLS, entropy, and cryptography.
- Pure state transitions for topology, selection, retries, transactions, and timeout accounting.
- Runtime adapters isolated from wire protocol and driver semantics.

The fake runtime is a first-class conformance tool. It must control time, task scheduling, partial I/O, cancellation, entropy, cryptographic responses, and injected failures. Missing fake scripts are test errors. Operational failures are returned through the same contracts used in production.

Language idioms should shape the implementation. Reuse specification behavior and reference-driver lessons, not class structures or incidental control flow.

## Executable roadmap

Represent the roadmap as a validated dependency graph. Each activity must be the smallest practical vertical behavior from a failing test through production code, upstream case activation, documentation, and a self-contained commit.

The activity workflow is:

1. Validate the plan, reference pins, generated state, and completed commit evidence.
2. Select and start exactly one ready activity.
3. Add the smallest failing behavior test and record the red result.
4. Implement only the behavior required by that slice.
5. Identify every upstream case made applicable by the change.
6. Enable and execute those cases in the same activity.
7. Run the narrowest effective local tests and validators, recording the green result with execution counts.
8. Update architecture, compatibility, capability records, and the conformance ledger.
9. Complete the activity and commit its exact subject with exactly one `Plan-Activity` trailer.
10. Push the commit, run `check --strict --pushed`, and require the per-commit `CI Fast` GitHub Actions run to pass before selecting another activity. The next `start` transition independently refuses to proceed until all completed activity commits are unique and remote-reachable. Scheduled full-conformance status is release evidence and does not pause an otherwise green ordinary slice.

Do not use a release activity to construct missing conformance infrastructure or discover broad semantic gaps. Release hardening should verify a matrix that is already green.

## Local and CI verification

Local testing provides rapid, deterministic evidence for the behavior being changed. It is not a smaller imitation of the entire CI pipeline. Use `make test-focus` with explicit selectors and choose the minimum set that can falsify the slice:

- Re-run the exact test that established red evidence.
- Add the nearest integration case when behavior crosses a module, protocol, runtime, or server boundary.
- Run only the newly applicable unified fixture or fixture family with `FOCUS_UNIFIED`.
- Lint the touched Lua production and test files with `FOCUS_LINT`.
- Run a format-specific validator when changing a generated ledger, capability map, compatibility projection, rockspec, workflow, or planning document.

Broaden local testing only when the change affects a shared primitive, targeted evidence exposes adjacent risk, or the slice changes test infrastructure. A slice is locally verified when its focused evidence is green and integrated after required fast CI passes. Complete live unified execution, coverage, and the supported live server matrix run in `Full Conformance`: nightly on Linux, weekly on macOS, on demand for any selected commit, and before release. Linux unified execution is partitioned into four deterministic fixture-level shards, each with isolated standalone and replica-set deployments; a dependent job rejects incomplete shard evidence, reconstructs the global report, and enforces the ordinary unsharded ratchets. Its retained report also records preprocessing, environment-provisioning, fixture-group, and total worker durations plus a stable slowest-group view; these observations are diagnostic and never participate in conformance identity or ratchets. Each fixture batch also emits flushed start and completion diagnostics to stderr with its environment, position, elapsed time, and exact outcome counts, while report JSON remains isolated on stdout or in its requested artifact. Static, portable, stress, packaging, and coverage checks run independently from those shards. Full-conformance failures remain visible, attributable to their exact commit, and release-blocking without forcing every vertical slice to wait for the complete matrix.

Shard selection normally keeps every fixture atomic so its tests retain one batched executor. The measured `transactions/tests/unified/mongos-pin-auto.json` group is the sole exception: its 56 runnable identities are distributed evenly by their stable upstream test index, preserving exact aggregation while removing a 46–53 minute single-shard bottleneck.

The repository exposes the same distinction as explicit compositions. `make check-fast` contains deterministic per-change verification without complete live unified execution or coverage instrumentation. `make check-full` adds those authoritative broad gates, and `make check` remains its release-oriented alias. Static fixture validation is shared by both compositions and runs exactly once.

## Test and conformance layers

No single test layer establishes driver correctness. Use complementary layers with explicit responsibilities.

### Normative fixture suites

Execute every applicable upstream corpus in its native format. This includes unified tests and legacy formats for BSON, connection strings, SDAM, server selection, CMAP, sessions, timeout behavior, and other specifications.

Maintain one machine-readable conformance ledger that records, for every suite and test case:

- Stable source identity and content fingerprint.
- Pinned specifications commit.
- Runner and test format.
- Scope and required environment.
- Current status and last execution evidence.
- Owning roadmap activity for any unsupported capability.

Fixture additions, removals, content changes, missing runners, and stale ledger entries must fail validation.

### Unit and model tests

Use focused unit tests for language API contracts, input validation, local command construction, immutable values, and structured errors. Use official corpora wherever the specification provides them.

Use model- and property-based tests for stateful or combinatorial behavior such as:

- BSON and Extended JSON round trips.
- Message size accounting and malformed frames.
- URI normalization and precedence.
- SDAM transitions and selection invariants.
- Pool generations, waiters, clears, and cancellation.
- Retry and transaction state machines.
- One-budget timeout propagation.

Randomized tests must accept and report a seed so failures are reproducible.

### Deterministic integration tests

Use scripted loopback peers and the fake runtime to exercise exact byte transfer, protocol framing, authentication conversations, TLS policy, timing, and failure injection. Inject failures at every meaningful blocking or state-transition boundary.

These tests are integration tests, but they do not replace compatibility testing against real MongoDB deployments.

### Live compatibility tests

Run the supported server range in reproducible CI jobs. Cover every in-scope topology and the required authentication, TLS, and test-command configurations. Record exact server and dependency versions in machine-readable reports.

Environment requirements must produce an explicit environment skip. They must not be confused with an unsupported driver capability or a passing test.

### Coverage and stress gates

Collect source and branch coverage where the language tooling permits it. Ratchet thresholds so coverage cannot regress silently. Coverage is a diagnostic and regression signal, not a substitute for specification cases.

Repeat deterministic race, cancellation, failover, and cleanup schedules. Preserve the seed and environment for every failure. Add leak checks for sockets, checked-out connections, tasks, sessions, cursors, transactions, and failpoints.

## Unified test runner

The unified runner is production conformance infrastructure, not a fixture inventory tool. Keep the format interpreter independent from driver adapters, but exercise both together.

The execution pipeline is:

1. Discover fixture files and stable test identities.
2. Parse through the driver's Extended JSON implementation.
3. Validate the declared schema version and reject incompatible files.
4. Validate the fixture document against the supported schema.
5. Discover environment facts with an internal client.
6. Evaluate file- and test-level run-on requirements.
7. Prepare initial data with the required concerns and topology rules.
8. Create a fresh, typed entity map for one test.
9. Attach only the requested event and log collectors.
10. Resolve and validate operation arguments, execute operations, and assert results or complete error expectations.
11. Disable listeners and failpoints even after failures.
12. Match event and log sequences.
13. Read outcomes through the internal client and compare exact documents in `_id` order.
14. Expose final entities when requested, then close sessions, cursors, clients, threads, and transactions.
15. Emit one result row per test and continue safely to the next test.

Use the upstream unified-format `valid-pass` and `valid-fail` suites as runner conformance tests, not only as schema inputs. Server-independent cases should run deterministically; cases requiring a deployment should run in the appropriate live matrix.

Unknown entities, operations, arguments, event types, match operators, or schema versions are failures. Intentionally unimplemented capabilities may be deferred only through the capability system.

### Per-test capability model

Classify individual tests, not entire files. One file may mix supported and unsupported operations.

Derive capability requirements where possible from:

- Entity kinds and options.
- Entity operations and arguments.
- Special runner operations.
- Expected event and log kinds.
- Match operators and expected-error fields.
- Topology, server-version, authentication, encryption, and test-command requirements.

Use narrow explicit overrides only when static extraction is insufficient. Every deferral must have a structured reason and an existing pending roadmap owner. A completed owner may not retain deferred cases. Unknown capabilities and reductions in runnable or passing baselines fail the gate.

Report at least these statuses separately:

- `passed`
- `failed`
- `skipped_environment`
- `deferred_unsupported`
- `excluded_scope`
- `invalid_or_incompatible`

Schema validation, inventory coverage, and an all-deferred report must never be presented as unified execution success.

## Using the reference implementation

For difficult behavior, triangulate among the specification prose, normative fixtures, and the pinned reference driver.

Use the reference implementation to study:

- Responsibility and cleanup boundaries.
- Result coercion into unified-format values.
- Error-label and partial-result handling.
- Event normalization and filtering.
- Failpoint targeting and cleanup.
- Session, retry, transaction, and timeout control flow.
- Environment discovery and topology setup.

Differential tests are useful for deterministic behavior such as BSON/Extended JSON conversion, URI parsing, command construction, and result coercion. Compare observable behavior, not private data structures. If the reference and specification disagree, follow the specification and document the difference.

## Measurement and release criteria

### Public compatibility projection

Present public specification compatibility in the architectural layer order described by the [MongoDB driver specifications onion model](https://alexbevi.com/specifications/): Serialization, Communication, Connectivity, Authentication, Availability, Resilience, Programmability, Observability, and Testability. This ordering is a documentation projection over the dependency graph; roadmap execution remains dependency-driven and does not need to force independent activities into a strictly linear layer sequence.

Derive the README table from the checked-in conformance ledger. A specification suite is fully implemented and validated only when every tracked case passes, partially implemented when passing and unsupported cases coexist, and not implemented when no tracked case passes. New or removed suites must fail generation until they are assigned to a driver layer. Keep case counts, implementation internals, architectural decisions, and detailed evidence in machine-readable reports and `docs/ARCHITECTURE.md`, not in the README.

The README is the stable public overview: project purpose, public API outline, scope, generated compatibility projection, development entry points, and license. Every activity may update architecture and evidence, but it updates the README only when one of those public overview surfaces changes.

Publish and ratchet metrics instead of relying on prose summaries:

- Discovered, parsed, schema-valid, executed, passed, failed, environment-skipped, deferred, and excluded unified tests.
- Counts by specification, operation, event type, topology, and owning activity.
- Legacy fixture totals and pass/defer counts.
- Source and branch coverage.
- Compatibility matrix cells exercised.
- Repeated stress schedules and retained failure seeds.
- Resource-leak and cleanup results.

A production milestone is releasable only when:

- Unknown and unclassified cases are zero.
- Applicable deferred cases are zero.
- No completed activity owns a deferral.
- Every environment-applicable in-scope test passes.
- Excluded and post-milestone cases have explicit scope decisions and real owners.
- The supported runtime, operating-system, server-version, topology, authentication, and TLS matrix is green.
- Packaging, security redaction, cleanup, and strict commit evidence gates pass.

## Reproducing the method for another language

To apply this strategy to another driver:

1. Pin the MongoDB specifications and one mature reference driver at exact commits.
2. Declare the intended feature, server, topology, runtime, and platform scope.
3. Map specification suites and reference-driver symbols to planned components.
4. Establish ordered BSON, Extended JSON, structured errors, and injectable runtime boundaries.
5. Build the validated activity DAG and evidence ledger before broad feature work.
6. Import normative corpora instead of translating them by hand.
7. Build schema validation and the unified runner from upstream meta-tests.
8. Execute the first real unified case as soon as the minimal public API exists.
9. Enable newly applicable cases in every subsequent implementation activity.
10. Add live server/topology matrices before claiming compatibility.
11. Measure and ratchet conformance, coverage, stress, and cleanup evidence.
12. Keep language-specific design decisions explicit while preserving observable specification behavior.

The reusable product is not a particular class layout. It is the chain from pinned requirements to deterministic tests, scoped implementation, executed upstream evidence, and reproducible compatibility reports.
