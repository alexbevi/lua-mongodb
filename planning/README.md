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
make test-focus FOCUS_UNIT=spec/unit/example_spec.lua FOCUS_LINT="src/mongodb/example.lua spec/unit/example_spec.lua"
make test-focus FOCUS_INTEGRATION=spec/integration/example_spec.lua
make test-focus FOCUS_UNIFIED='crud/tests/unified/example.json::test?1?'
make test-focus FOCUS_PYTHON=planning.tests.test_update_plan.CommitTests
```

`check` validates document shape, dependencies, cycles, generated state, and pinned references. `--strict` additionally requires exactly one commit with the completed activity's exact subject and exactly one matching `Plan-Activity` trailer, and rejects new reuse of that trailer. Published CI follow-up commits at or before the commit-policy baseline in `update_plan.py` are retained as an explicit history-only exception. `--strict --pushed` also requires the canonical commit to be reachable from a remote-tracking ref. Starting another activity applies the pushed check automatically. `refresh` only regenerates derived state; it never changes plan definitions or reference pins.

Named tracks provide an execution view over the same activity DAG. Each declaration identifies its entry, terminal, and prerequisite activity, and tracked activities name their declaration explicitly. `next --track TRACK` considers only ready members of that track; `current_state.json` exposes the same deterministic grouping as `ready_by_track`. Track selection does not change dependencies, statuses, or global plan order, and unscoped `next` retains its original first-ready behavior.

Starting post-v1 work requires `start ID --track TRACK`. The track must be declared and the activity must belong to it, so authorization for one goal cannot spill into unrelated ready post-v1 activities. Production-core starts remain backward compatible without a track. The agent retains the user's single track authorization across its loop and reasserts that scope on each start.

`update_readme_compatibility.py` projects the conformance ledger into the README's driver-layer compatibility table. Run it whenever ledger statuses change; CI uses `--check` so the README cannot drift from executable evidence.

Activity implementation follows red-green vertical slices. A `red_green` activity cannot complete without a recorded nonzero red command and successful green command. A `validation` activity requires successful green evidence. Only one activity may be `in_progress`.

`make test-focus` is the default local verification entry point. Every invocation requires an explicit selector, and multiple selectors may be combined when a slice crosses a directly coupled boundary. Full suites, coverage, stress, conformance reconciliation, platform checks, and the live compatibility matrix run in GitHub Actions after push. Run `make check` locally only for test-infrastructure changes, release preparation, cross-cutting primitives without a trustworthy focused boundary, or CI failure diagnosis.

Use `requeue` when an in-progress activity must return to pending before implementation continues, such as when reviewed roadmap dependencies need to be inserted ahead of it. The command preserves existing evidence and records the reason; it is not a substitute for `block` when work is genuinely blocked.

Use [`prompt_goal.md`](prompt_goal.md) to launch the incremental production-core implementation.
