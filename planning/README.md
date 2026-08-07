# Executable roadmap

`plan.json` is the reviewed, mostly immutable activity DAG. `progress.json` stores mutable activity status and evidence. `current_state.json` is a deterministic generated summary; never edit it by hand.

[`strategy.md`](strategy.md) documents the reproducible, specification-driven implementation and conformance method used by this project and intended for reuse by drivers in other languages.

The reference checkouts are pinned in `plan.json` and registered as Git submodules:

- `planning/pymongo` is the behavioral and structural reference.
- `planning/specifications` is the normative source and unified fixture corpus.

## Commands

```sh
python3 planning/update_plan.py check [--strict [--pushed]]
python3 planning/update_plan.py next [--json]
python3 planning/update_plan.py start ID
python3 planning/update_plan.py requeue ID --reason "..."
python3 planning/update_plan.py record-test ID --phase red --command "..." --exit-code 1 --summary "..."
python3 planning/update_plan.py record-test ID --phase green --command "..." --exit-code 0 --summary "..."
python3 planning/update_plan.py block ID --reason "..."
python3 planning/update_plan.py unblock ID
python3 planning/update_plan.py complete ID
python3 planning/update_plan.py refresh
python3 planning/update_plan.py reference-report
python3 planning/update_readme_compatibility.py [--check]
```

`check` validates document shape, dependencies, cycles, generated state, and pinned references. `--strict` additionally requires exactly one commit with the completed activity's exact subject and exactly one matching `Plan-Activity` trailer, and rejects new reuse of that trailer. Published CI follow-up commits at or before the commit-policy baseline in `update_plan.py` are retained as an explicit history-only exception. `--strict --pushed` also requires the canonical commit to be reachable from a remote-tracking ref. Starting another activity applies the pushed check automatically. `refresh` only regenerates derived state; it never changes plan definitions or reference pins.

`update_readme_compatibility.py` projects the conformance ledger into the README's driver-layer compatibility table. Run it whenever ledger statuses change; CI uses `--check` so the README cannot drift from executable evidence.

Activity implementation follows red-green vertical slices. A `red_green` activity cannot complete without a recorded nonzero red command and successful green command. A `validation` activity requires successful green evidence. Only one activity may be `in_progress`.

Use `requeue` when an in-progress activity must return to pending before implementation continues, such as when reviewed roadmap dependencies need to be inserted ahead of it. The command preserves existing evidence and records the reason; it is not a substitute for `block` when work is genuinely blocked.

Use [`prompt_goal.md`](prompt_goal.md) to launch the incremental production-core implementation.
