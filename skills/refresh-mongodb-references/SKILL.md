---
name: refresh-mongodb-references
description: Dry-run and review upstream PyMongo and MongoDB specifications changes, repin the planning submodules, update architecture mappings, and mark affected roadmap work for review. Use only when the user explicitly requests a source-reference refresh.
---

# Refresh MongoDB References

1. Read `AGENTS.md`, `planning/plan.json`, `planning/references.json`, `planning/reference_architecture.md`, and `planning/current_state.json`.
2. Run `python3 planning/update_plan.py check --strict --pushed` and `python3 planning/update_plan.py check-references` before changing anything.
3. Resolve each requested upstream target to one full commit SHA. When the user requests the latest default branch, resolve `HEAD` once with `git -C CHECKOUT ls-remote origin HEAD` and retain that SHA throughout the review. Do not use `git submodule update --remote`.
4. Run `python3 planning/update_references.py REFERENCE COMMIT --dry-run --format json`. Preserve the report even when the command exits nonzero for repeatable classification or generator failures.
5. Use `proposed_plan_items` to organize the review, then verify each proposal against its reported commits, paths, landmarks, activities, and inventory changes. Treat the proposals as candidates, not automatic roadmap edits. For specifications, inspect the upstream patches before deciding that a changed fingerprint has no Lua impact.
6. Do not accept a report whose generator simulation is not repeatable. For each verified semantic change to completed or active work, run `python3 planning/update_plan.py review ID --reason "..."`. Add only the smallest pending activities needed for new behavior and assign new classifications to concrete owners.
7. Advance the pin with `python3 planning/update_references.py REFERENCE COMMIT --expect-impact DIGEST`. A green simulation regenerates artifacts during the update. A reviewed report with repeatable generator failures moves only the pin; resolve its reported classifications or generator failures, then run `make update-spec-artifacts`.
8. Update `planning/references.json` mappings and `planning/reference_architecture.md` when upstream landmarks or project boundaries changed. Never accept a removed or renamed path or symbol without recording its replacement and affected activities.
9. Run `python3 planning/update_plan.py render-state`, `python3 planning/update_plan.py reference-report`, `python3 planning/update_plan.py check-references`, the focused planning tests, skill validation, and `python3 planning/update_plan.py check --strict`.
10. Commit the verified refresh as `chore(planning): refresh MongoDB references` with exactly one `Plan-Activity` trailer only when the plan assigns the refresh an activity. Push it and require `python3 planning/update_plan.py check --strict --pushed` plus the corresponding `CI Fast` run before starting implementation work.

Keep this workflow separate from driver implementation. Do not repin merely to repair local checkout drift.
