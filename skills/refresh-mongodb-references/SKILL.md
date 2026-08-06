---
name: refresh-mongodb-references
description: Review upstream PyMongo and MongoDB specifications changes, repin the planning submodules, update architecture mappings, and mark affected roadmap work for review. Use only when the user explicitly requests a source-reference refresh.
---

# Refresh MongoDB References

1. Read `AGENTS.md`, `planning/plan.json`, `planning/reference_architecture.md`, and current state.
2. Run `python3 planning/update_plan.py check --strict` before changing anything.
3. Fetch both submodule remotes without modifying their contents. Compare the pinned commits with the requested upstream targets.
4. Review changes to every mapped path and symbol plus unified-test schemas, runner behavior, and applicable specification suites.
5. Update submodule pins, plan reference metadata, mappings, and `planning/reference_architecture.md` together. Do not silently accept removed or renamed symbols.
6. Mark completed or active activities affected by semantic drift as `needs_review`; preserve evidence and explain each impact in progress notes.
7. Run `refresh`, `reference-report`, planning tests, skill validation, and `check --strict`.
8. Commit the verified refresh as `chore(planning): refresh MongoDB references` with the appropriate `Plan-Activity` trailer when the plan assigns one.

Keep this workflow separate from driver implementation. Do not repin merely to repair local checkout drift.
