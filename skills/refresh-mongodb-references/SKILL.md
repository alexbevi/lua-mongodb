---
name: refresh-mongodb-references
description: Dry-run and review upstream PyMongo and MongoDB specifications changes, repin the planning submodules, update architecture mappings, and mark affected roadmap work for review. Use only when the user explicitly requests a source-reference refresh.
---

# Refresh MongoDB References

1. Read `AGENTS.md`, `planning/plan.json`, `planning/references.json`, `planning/reference_architecture.md`, and `planning/current_state.json`.
2. Run `python3 planning/update_plan.py check --strict --pushed` and `python3 planning/update_plan.py check-references` before changing anything.
3. Resolve each requested upstream target to one full commit SHA. When the user requests the latest default branch, resolve `HEAD` once with `git -C CHECKOUT ls-remote origin HEAD` and retain that SHA throughout the review. Do not use `git submodule update --remote`.
4. Run `python3 planning/update_references.py REFERENCE COMMIT --dry-run --format json`. Preserve the report even when artifact generation fails. Use the reported waypoint when a repeatable failure identifies an earlier passing commit.
5. Review actionable and blocked proposals first. Use `--show relevant` for deferred work and `--show all` for informational changes. Verify proposals against the exact specification owners or categorized PyMongo paths in the full JSON report. Treat proposals as candidates, not automatic roadmap edits.
6. Do not accept nonrepeatable artifact generation. New deferred cases owned by pending activities do not require implementation or activity review. For semantic changes owned by completed or active activities, run `python3 planning/update_plan.py review ID --reason "..."`. Add only the smallest pending activities needed for unowned behavior.
7. Inspect `behavior_verification.commands`, `unverified_identities`, and required environments. A broad command is not evidence for a new case unless it discovers that suite; otherwise require a command that names the changed source. When every required environment is available, rerun the dry run with `--verify`. Advance the pin with `python3 planning/update_references.py REFERENCE COMMIT --expect-impact DIGEST` only after reviewing any unverified behavior. A reviewed report with repeatable generator failures moves only the pin; resolve its classifications or generator failures, then run `make update-spec-artifacts`.
8. Update `planning/references.json` mappings and `planning/reference_architecture.md` when upstream landmarks or project boundaries changed. Never accept a removed or renamed path or symbol without recording its replacement and affected activities.
9. Run `python3 planning/update_plan.py render-state`, `python3 planning/update_plan.py reference-report`, `python3 planning/update_plan.py check-references`, the focused planning tests, skill validation, and `python3 planning/update_plan.py check --strict`.
10. Commit the verified refresh as `chore(planning): refresh MongoDB references` with exactly one `Plan-Activity` trailer only when the plan assigns the refresh an activity. Push it and require `python3 planning/update_plan.py check --strict --pushed` plus the corresponding `CI Fast` run before starting implementation work.

Keep this workflow separate from driver implementation. Do not repin merely to repair local checkout drift.
