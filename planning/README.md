# Executable roadmap

`plan.json` is the reviewed, mostly immutable activity DAG. `progress.json` stores mutable activity status and evidence. `current_state.json` is a deterministic generated summary; never edit it by hand.

The reference checkouts are pinned in `plan.json` and registered as Git submodules:

- `planning/pymongo` is the behavioral and structural reference.
- `planning/specifications` is the normative source and unified fixture corpus.

## Commands

```sh
python3 planning/update_plan.py check [--strict]
python3 planning/update_plan.py next [--json]
python3 planning/update_plan.py start ID
python3 planning/update_plan.py record-test ID --phase red --command "..." --exit-code 1 --summary "..."
python3 planning/update_plan.py record-test ID --phase green --command "..." --exit-code 0 --summary "..."
python3 planning/update_plan.py block ID --reason "..."
python3 planning/update_plan.py unblock ID
python3 planning/update_plan.py complete ID
python3 planning/update_plan.py refresh
python3 planning/update_plan.py reference-report
```

`check` validates document shape, dependencies, cycles, generated state, and pinned references. `--strict` additionally verifies completed-activity commit subjects and `Plan-Activity` trailers when the workspace is a Git repository. `refresh` only regenerates derived state; it never changes plan definitions or reference pins.

Activity implementation follows red-green vertical slices. A `red_green` activity cannot complete without a recorded nonzero red command and successful green command. A `validation` activity requires successful green evidence. Only one activity may be `in_progress`.

Use [`prompt_goal.md`](prompt_goal.md) to launch the incremental production-core implementation.

