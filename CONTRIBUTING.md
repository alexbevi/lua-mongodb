# Contributing

Thank you for improving the Lua MongoDB driver. Start with the smallest change that fixes one
observable behavior. MongoDB specifications are normative. The pinned PyMongo checkout is the
behavioral reference when a specification leaves an implementation detail open, but the Lua
implementation should keep idiomatic Lua boundaries.

Read the [architecture](docs/ARCHITECTURE.md) before changing production boundaries. Report a
suspected vulnerability through the private route in the [security policy](SECURITY.md), not in a
public issue or pull request.

## Development environment

The supported development matrix is Lua 5.4 and Lua 5.5 with a 64-bit `lua_Integer` on Linux and
macOS. Install LuaRocks 3.13, Python 3, OpenSSL development files, and Zstandard development files.
The default runtime also requires the dependencies declared in the current rockspec.

Clone the pinned reference repositories without moving their commits:

```sh
git submodule update --init --recursive
```

Install the runtime and common test dependencies used by CI:

```sh
luarocks install --only-deps mongodb-0.10.6-1.rockspec
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
`make check-fast-runtime` and leaves source lint to the Lua 5.4 lane. On macOS, pass the Homebrew
OpenSSL and Zstandard prefixes when native modules cannot discover them. The CI workflow contains
the current setup commands.

Deterministic unit tests and most loopback integration tests do not need MongoDB Server. A running
Docker daemon is needed only for the image-backed live compatibility matrix. For example:

```sh
make test-compatibility-live COMPATIBILITY_ENTRY=mongodb-7.0-standalone
```

Leave the complete version and topology matrix to CI unless you are diagnosing its infrastructure.
Do not edit either pinned submodule or move a reference commit during an ordinary contribution.

## Making a change

Use this path for an ordinary pull request:

1. Choose one independently useful behavior or documentation correction.
2. Add or update the smallest test that demonstrates the behavior. For a bug, run it once to
   confirm that it fails for the expected reason.
3. Implement only the change needed to make that test pass.
4. Run the focused test and any directly affected checks.
5. Update public documentation, architecture, classifications, or generated evidence only when
   their contracts changed.
6. Commit the passing slice with a Conventional Commit subject.

Do not combine unrelated cleanup with the change. A normal contribution does not need a roadmap
activity, planning track, planning-state update, or `Plan-Activity` trailer.

### Maintainer roadmap work

Some maintainer-assigned work is tied to an existing roadmap activity. Only use that workflow when
a maintainer has assigned the activity and its declared track. In that case, follow
[the agent working agreement](AGENTS.md) and [the planning command guide](planning/README.md),
including red and green evidence, the exact commit subject and trailer, the pushed-state check, and
the required `CI Fast` result.

Do not create a planning activity for an ordinary contribution. Never edit
`planning/current_state.json` by hand.

## Focused local verification

`make test-focus` is the ordinary local entry point. Select the narrowest boundaries that can
falsify the change. Selectors can be combined:

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
change. Add `make test-complexity` when production control flow changes. Run the validator owned by
any generated artifact, rockspec, or workflow touched by the change.

The broader compositions have distinct roles:

- `make check-fast-runtime` runs portable verification for the active Lua runtime without lint or
  the complexity ratchet.
- `make check-fast` adds lint and complexity and is the required fast gate under Lua 5.4.
- `make check-full` adds complete live unified execution and coverage. `make check` is its release
  alias.

Broad suites are useful for test-infrastructure changes, release preparation, cross-cutting
primitives without a trustworthy focused boundary, and CI-only failure diagnosis. They are not
normally needed for a small pull request.

## Generated files and upstream fixtures

Do not edit generated conformance, scope, capability, compatibility, coverage, complexity, or
Unicode-table outputs by hand. Change their source and run the owning generator or its `--check`
mode. Common checks include:

```sh
python3 spec/conformance/catalog.py --check
python3 spec/conformance/ledger.py --check
python3 planning/update_readme_compatibility.py --check
```

When conformance-ledger or projected catalog status changes, run
`python3 planning/update_readme_compatibility.py` and commit the resulting README table. The full
artifact command catalog lives in [the planning guide](planning/README.md).

Every upstream fixture must execute or retain an explicit deferral with a reason. Unknown unified
operations are failures and must not become silent skips.

## Changelog entries

Update `CHANGELOG.md` when a published-driver change affects users. Write for someone deciding
whether to upgrade, not for the implementation record.

- Keep releases in reverse chronological order under `## [VERSION] - YYYY-MM-DD`.
- Use relevant headings such as `Added`, `Changed`, `Fixed`, `Deprecated`, `Removed`, and
  `Security`. Omit empty headings.
- Describe observable behavior, affected users, new requirements, and required migration steps.
- Add a short `Example` for a new public API or option when code explains it better than prose.
  Use only public entry points and keep the snippet valid under a supported Lua version.
- Leave activity identifiers, fixture counts, CI jobs, checklist gates, and publication mechanics
  in their owning planning, test, architecture, or release artifacts.

Combine related work into one release-level explanation. Do not copy commit subjects or roadmap
summaries into the changelog.

## CI and review evidence

`CI Fast` runs after every push. It executes `make check-fast` on Linux and macOS under Lua 5.4,
runtime verification under Lua 5.5, installed-rock examples, and live compatibility boundary rows.

`Full Conformance` is scheduled and can be requested manually for an exact commit. It owns complete
live unified execution, coverage, the full server and topology matrix, nightly Linux evidence, and
weekly macOS evidence. A known failure blocks a release.
