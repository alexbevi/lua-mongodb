# Contributing

Changes are developed as small, test-first roadmap activities. Before proposing implementation,
read the [architecture](docs/ARCHITECTURE.md), [implementation strategy](planning/strategy.md),
and [agent working agreement](AGENTS.md). MongoDB specifications are normative; the pinned
PyMongo checkout is the behavioral reference when the specification leaves implementation detail
open. Use idiomatic Lua boundaries rather than copying Python structure.

Report a suspected vulnerability through the private route in the
[security policy](SECURITY.md), not through a public contribution.

## Development environment

The supported development matrix is Lua 5.4 and Lua 5.5 with a 64-bit `lua_Integer` on Linux and
macOS. Install LuaRocks 3.13, Python 3, OpenSSL development files, and Zstandard development files.
The default runtime also requires the dependencies declared in the current rockspec.

Clone the two pinned reference repositories without moving their commits:

```sh
git submodule update --init --recursive
```

Install the runtime and common test dependencies used by CI:

```sh
luarocks install --only-deps mongodb-0.10.1-1.rockspec
luarocks install busted 2.3.0-1
luarocks install lua-csnappy 0.1.5-2
luarocks install lua-zstd 0.2.0-1
```

For the complete Lua 5.4 quality gate, also install its lint and coverage tools:

```sh
luarocks install luacheck 1.2.0-1
luarocks install luacov 0.17.0-1
```

Luacheck 1.2 does not execute under Lua 5.5, so the Lua 5.5 lane uses
`make check-fast-runtime` and leaves source lint to the Lua 5.4 lane.

On macOS, pass the Homebrew OpenSSL and Zstandard prefixes when native modules cannot discover
them; `.github/workflows/ci.yml` is the executable setup reference. Deterministic unit tests and
most loopback integration tests do not need MongoDB Server. Live unified and compatibility work
uses the exact MongoDB versions and topologies selected by the CI workflows.

A running Docker daemon is required only for the image-backed live compatibility matrix. For
example, `make test-compatibility-live COMPATIBILITY_ENTRY=mongodb-7.0-standalone` provisions the
exact pinned image and profile from `spec/compatibility/matrix.json`. The complete matrix covers
MongoDB 7.0, 8.0, and 8.2 across standalone, replica-set, and sharded topologies; leave broad
matrix execution to CI unless diagnosing that infrastructure.

Do not edit either pinned submodule or move a reference commit during ordinary implementation.
A reference refresh is a separate maintainer-authorized activity.

## Activity and commit workflow

Coordinate a roadmap activity and any required track with the maintainer before writing code.
Only one activity may be in progress. Validate state and select the agreed activity with the
commands documented in `planning/README.md`:

```sh
python3 planning/update_plan.py check --strict --pushed
python3 planning/update_plan.py next --track TRACK
python3 planning/update_plan.py start ID --track TRACK
```

Add the smallest test that defines one independently useful behavior and run it to establish a
failure. Record that command with `record-test --phase red`, implement only the behavior needed
for the slice, then record focused passing evidence with `record-test --phase green`. Update
architecture, classifications, compatibility evidence, and public documentation only when the
behavior changes those contracts.

After the focused checks pass, complete the activity and regenerate planning state:

```sh
python3 planning/update_plan.py complete ID
python3 planning/update_plan.py refresh
```

Use the activity's exact Conventional Commit subject and exactly one `Plan-Activity: ID` trailer.
Never commit a red test state or combine unrelated cleanup with the activity. Push the commit,
run `python3 planning/update_plan.py check --strict --pushed`, and wait for its `CI Fast` run
before starting another activity.

## Focused local verification

`make test-focus` is the ordinary local entry point. Select the narrowest boundaries that can
falsify the change; selectors can be combined:

```sh
make test-focus FOCUS_UNIT=spec/unit/error_spec.lua
make test-focus FOCUS_INTEGRATION=spec/integration/crud_spec.lua
make test-focus FOCUS_UNIFIED=crud/tests/unified/count-empty.json
make test-focus FOCUS_PYTHON=planning.tests.test_readme_content
make test-focus FOCUS_UNIT=spec/unit/error_spec.lua \
  FOCUS_LINT='src/mongodb/error.lua spec/unit/error_spec.lua'
```

The available selectors are `FOCUS_UNIT`, `FOCUS_INTEGRATION`, `FOCUS_UNIFIED`, `FOCUS_PYTHON`,
and `FOCUS_LINT`. Add `make test-architecture` when production dependencies or runtime boundaries
change. Add `make test-complexity` when production control flow changes. Run the validator owned
by any generated artifact, rockspec, or workflow touched by the slice.

The broader compositions have distinct roles:

- `make check-fast-runtime` runs portable verification for the active Lua runtime without lint
  or the complexity ratchet.
- `make check-fast` adds lint and complexity and is the required fast gate under Lua 5.4.
- `make check-full` adds complete live unified execution and coverage; `make check` is its release
  alias.

Do not run broad suites locally for an ordinary slice. They are appropriate for test-infrastructure
changes, release preparation, cross-cutting primitives without a trustworthy focused boundary,
or CI-only failure diagnosis.

## Generated files and pinned evidence

Never edit `planning/current_state.json`; `planning/update_plan.py refresh` derives it from the
validated plan and progress records. Update activity status and test evidence only through
`planning/update_plan.py`. Do not edit generated conformance, scope, capability, compatibility,
coverage, complexity, or Unicode-table outputs by hand; change their source and use the owning
generator or its `--check` mode. The central checks include:

```sh
python3 spec/conformance/catalog.py --check
python3 spec/conformance/ledger.py --check
python3 planning/update_readme_compatibility.py --check
```

When conformance-ledger or projected catalog status changes, run
`python3 planning/update_readme_compatibility.py` and commit the resulting README table. The full
artifact and planning command catalog lives in `planning/README.md`.

Every upstream fixture must execute or retain an explicit deferral with a reason. Unknown unified
operations are failures; never turn one into a silent skip.

## CI and review evidence

`CI Fast` runs after every push. It executes `make check-fast` on Linux and macOS under Lua 5.4,
runtime verification under Lua 5.5, installed-rock examples, and live compatibility boundary
rows. Fix a required failure before another activity begins.

`Full Conformance` is scheduled and can be requested manually for an exact commit. It owns
complete live unified execution, coverage, the full server/topology matrix, nightly Linux
evidence, and weekly macOS evidence. Ordinary activities do not wait for it, but a known failure
is release-blocking. Release publication requires the complete exact-commit evidence described in
the architecture and release checklist.
