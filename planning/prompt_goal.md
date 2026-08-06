# Copy/paste goal

```text
/goal Execute the production-core-v1 milestone in planning/plan.json. Read AGENTS.md and use $execute-driver-slice for every activity. Begin with `python3 planning/update_plan.py check --strict` and `next`. Implement exactly one ready vertical slice at a time: start it through update_plan.py, define and run the smallest failing test, record red evidence, implement only the slice, iterate to green, run its broader verification, record green evidence, update required architecture/README/spec classifications, complete and refresh state, then create its exact Conventional Commit with a `Plan-Activity: ID` trailer. Never edit pinned submodules or reference commits, never wrap libmongoc, never silently skip an unknown unified operation, and keep runtime-specific networking/TLS/crypto behind adapters. Continue incrementally until every production-core-v1 activity is complete and all strict, unit, integration, unified, lint, packaging, and compatibility gates pass. Stop before post-v1 activities. Stop early only for a genuine blocker that cannot be resolved safely in scope; record the blocker and report the needed user decision.
```

