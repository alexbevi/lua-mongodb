# Agent working agreement

## Authority and scope

Use sources in this order: MongoDB specifications are normative; the pinned PyMongo checkout is the behavioral reference; `docs/ARCHITECTURE.md` records project decisions; implementation code follows all three. Never copy Python structure mechanically when idiomatic Lua needs a smaller boundary.

Read `skills/execute-driver-slice/SKILL.md` before implementing a roadmap activity. Use `skills/refresh-mongodb-references/SKILL.md` only when the user explicitly requests a reference refresh. Do not edit either submodule or change a reference pin during normal implementation.

The production goal stops after `production-core-v1`. Do not begin post-v1 work unless explicitly requested. Never bind or wrap `libmongoc`; keep driver, BSON, wire-protocol, topology, and selection logic in Lua. Networking, TLS, and cryptography belong behind runtime adapters.

## Activity workflow

Keep commits small. Each commit must be the smallest practical vertical slice that delivers one independently verifiable behavior from its tests through its implementation and required documentation. If an activity is too large for one such commit, split it into ordered plan activities before implementation; never accumulate several behaviors into a broad checkpoint commit.

1. Run `python3 planning/update_plan.py check --strict` and `next`.
2. Start exactly one ready activity through the script.
3. Add the smallest failing test that defines the vertical slice, run it, and record the red result.
4. Implement only enough production behavior for the slice, preserving public contracts.
5. Run targeted tests and the relevant broader gates until green; record green evidence.
6. Update `docs/ARCHITECTURE.md`, spec classifications, and compatibility evidence when behavior changes. Keep implementation design, internal behavior, and detailed verification evidence out of `README.md`; that file is limited to the project overview, public API outline, scope, generated specification-compatibility table, development entry points, and license. When the conformance ledger changes, run `python3 planning/update_readme_compatibility.py` and commit the resulting table.
7. Complete and refresh state through `update_plan.py`.
8. Commit one self-contained, verifiable unit with the activity's exact Conventional Commit subject and a `Plan-Activity: ID` trailer.
9. Run strict validation again.

Never commit a red test state, silently skip an unknown unified operation, edit `current_state.json`, or mix unrelated cleanup into an activity. Every upstream fixture must be run or explicitly classified as deferred with a reason.

## Lua conventions

Follow the Lua Style Guide at <http://lua-users.org/wiki/LuaStyleGuide>: use two-space indentation; declare locals; return a module table named `M`; use `snake_case` for variables/functions and lowercase module paths; use `ALL_CAPS` for constants; avoid `module(...)`, deprecated facilities, and the debug library. Prefer small tables and functions over class emulation. Public object methods use colon syntax.

Target Lua 5.4 and require a 64-bit `lua_Integer`. Treat operational failures as values following the structured error contract; reserve `error()` for programmer errors and violated internal invariants.

## Verification

Once the foundation activity creates the build harness, the standard gates are `make test-unit`, `make test-integration`, `make test-unified`, `make lint`, and `make check`. Until then, use `python3 -m unittest discover -s planning/tests -v` and both skill validators.
