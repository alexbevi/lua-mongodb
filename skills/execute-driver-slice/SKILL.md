---
name: execute-driver-slice
description: Execute one test-first vertical slice from the Lua MongoDB driver roadmap, including state transitions, reference consultation, verification, documentation, and a self-contained Conventional Commit. Use when implementing the next or a named activity in planning/plan.json.
---

# Execute Driver Slice

1. Read `AGENTS.md`, `planning/plan.json`, `planning/current_state.json`, and the activity's mapped references.
2. Run `python3 planning/update_plan.py check --strict --pushed` and select a ready activity with `next`. Confirm it describes one independently verifiable behavior; if it combines operations, fixture families, or acceptance behaviors, split it into ordered activities and commit the plan split before implementation. Stop if dependencies or reference pins are invalid.
3. Start only that activity with `start ID`. Do not edit submodules, reference pins, or unrelated files.
4. Write the smallest test that specifies the activity's vertical behavior. Run it and record the failing result with `record-test ID --phase red`.
5. Implement the Lua behavior behind the documented architecture and runtime boundaries. Follow `AGENTS.md` style and error rules.
6. Inspect the pinned specification suites for cases made applicable by the behavior. Enable and run every newly applicable case in the same activity; classify remaining cases at test-case granularity with a concrete reason and a real pending roadmap owner.
7. Iterate on targeted tests, then run all verification commands listed by the activity. A schema, inventory, or all-deferred report is not evidence of unified execution. Record a passing result with `record-test ID --phase green` that states executed, passed, environment-skipped, deferred, and failed counts where applicable.
8. Update architecture, compatibility evidence, the conformance ledger, and unified capability records required by the activity. Put implementation details and design decisions in `docs/ARCHITECTURE.md`. Update `README.md` only when its overview, public API outline, scope, development entry points, license, or generated specification-compatibility projection changes; refresh that projection with `python3 planning/update_readme_compatibility.py`. Unknown capabilities, missing owners, deferrals owned by completed activities, and reductions in the runnable or passing baseline are failures.
9. Run `complete ID`, `refresh`, and `check`. Inspect the diff for one coherent unit.
10. Commit using the activity's exact Conventional Commit subject and add exactly one `Plan-Activity: ID` trailer. Push the commit, then run `check --strict --pushed`. Do not start another activity until the pushed check passes.

Never commit failing tests. Treat unknown unified operations as failures, and record a reason for every deferred upstream fixture. Stop at a genuine blocker instead of broadening scope.
