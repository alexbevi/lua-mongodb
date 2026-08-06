---
name: execute-driver-slice
description: Execute one test-first vertical slice from the Lua MongoDB driver roadmap, including state transitions, reference consultation, verification, documentation, and a self-contained Conventional Commit. Use when implementing the next or a named activity in planning/plan.json.
---

# Execute Driver Slice

1. Read `AGENTS.md`, `planning/plan.json`, `planning/current_state.json`, and the activity's mapped references.
2. Run `python3 planning/update_plan.py check --strict` and select a ready activity with `next`. Stop if dependencies or reference pins are invalid.
3. Start only that activity with `start ID`. Do not edit submodules, reference pins, or unrelated files.
4. Write the smallest test that specifies the activity's vertical behavior. Run it and record the failing result with `record-test ID --phase red`.
5. Implement the Lua behavior behind the documented architecture and runtime boundaries. Follow `AGENTS.md` style and error rules.
6. Iterate on targeted tests, then run all verification commands listed by the activity. Record a passing result with `record-test ID --phase green`.
7. Update architecture, README, compatibility, and unified-fixture classifications required by the activity.
8. Run `complete ID`, `refresh`, and `check`. Inspect the diff for one coherent unit.
9. Commit using the activity's exact Conventional Commit subject and add `Plan-Activity: ID` as a trailer. Run `check --strict` after committing.

Never commit failing tests. Treat unknown unified operations as failures, and record a reason for every deferred upstream fixture. Stop at a genuine blocker instead of broadening scope.

