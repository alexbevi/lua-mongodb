LUA ?= lua
LUAROCKS ?= luarocks
BUSTED ?= busted
LUACHECK ?= luacheck
LUACOV ?= luacov
PYTHON ?= python3

ROCKSPEC := lua-mongodb-scm-1.rockspec
BUSTED_PATHS := --lpath=src/?.lua --lpath=src/?/init.lua

.PHONY: check check-tools check-lua check-busted check-luacheck check-luacov check-luarocks check-python \
	test-unit test-integration test-unified test-unified-schema test-unified-inventory \
	test-unified-meta test-unified-execution test-conformance test-quality test-coverage \
	test-stress test-compatibility test-compatibility-live test-release-scope lint rockspec planning-check

check: test-unit test-integration test-unified test-quality test-compatibility lint rockspec planning-check

check-tools: check-lua check-busted check-luacheck check-luacov check-luarocks check-python

check-lua:
	@command -v "$(LUA)" >/dev/null 2>&1 || { \
		echo "Lua 5.4 interpreter not found; set LUA=/path/to/lua" >&2; exit 127; \
	}
	@"$(LUA)" -e 'assert(_VERSION == "Lua 5.4", "lua-mongodb requires Lua 5.4")'
	@"$(LUA)" -e 'assert(math.maxinteger >= 0x7fffffffffffffff, \
		"lua-mongodb requires 64-bit lua_Integer")'

check-busted: check-lua
	@command -v "$(BUSTED)" >/dev/null 2>&1 || { \
		echo "Busted not found; install test dependencies with LuaRocks" >&2; exit 127; \
	}

check-luacheck: check-lua
	@command -v "$(LUACHECK)" >/dev/null 2>&1 || { \
		echo "Luacheck not found; install test dependencies with LuaRocks" >&2; exit 127; \
	}

check-luacov: check-lua
	@command -v "$(LUACOV)" >/dev/null 2>&1 || { \
		echo "LuaCov not found; install test dependencies with LuaRocks" >&2; exit 127; \
	}

check-luarocks:
	@command -v "$(LUAROCKS)" >/dev/null 2>&1 || { \
		echo "LuaRocks not found; install LuaRocks for packaging checks" >&2; exit 127; \
	}

check-python:
	@command -v "$(PYTHON)" >/dev/null 2>&1 || { \
		echo "Python 3 not found; set PYTHON=/path/to/python3" >&2; exit 127; \
	}

test-unit: check-busted check-python
	@"$(BUSTED)" $(BUSTED_PATHS) spec/unit
	@"$(PYTHON)" spec/corpus/run_bson_corpus.py --lua "$(LUA)"
	@"$(PYTHON)" spec/corpus/run_bson_vector.py --lua "$(LUA)"

test-integration: check-busted
	@if test -n "$$(find spec/integration -type f -name '*_spec.lua' -print -quit 2>/dev/null)"; then \
		"$(BUSTED)" $(BUSTED_PATHS) spec/integration; \
	else \
		echo "test-integration: no integration slices yet (first added by CMD-001)"; \
	fi

test-unified: test-unified-schema test-unified-inventory test-unified-meta \
	test-unified-execution

test-unified-schema: check-busted check-python
	@"$(BUSTED)" $(BUSTED_PATHS) spec/unified/schema_spec.lua
	@"$(PYTHON)" spec/unified/validate_fixtures.py --lua "$(LUA)"

test-unified-inventory: check-python check-lua
	@"$(PYTHON)" spec/unified/validate_fixtures.py --lua "$(LUA)"
	@"$(PYTHON)" -m unittest spec.unified.test_cli -v
	@"$(PYTHON)" spec/unified/update_capabilities.py --check
	@$(MAKE) --no-print-directory test-conformance

test-conformance: check-python test-release-scope
	@"$(PYTHON)" -m unittest spec.conformance.test_ledger -v
	@"$(PYTHON)" spec/conformance/ledger.py --check

test-release-scope: check-python
	@"$(PYTHON)" -m unittest spec.release.test_scope -v
	@"$(PYTHON)" spec/release/scope.py --check

test-quality: test-coverage test-stress

test-coverage: check-busted check-luacov check-python
	@mkdir -p build/quality
	@"$(LUA)" -e 'os.remove("build/quality/luacov.stats.out"); os.remove("build/quality/luacov.report.out")'
	@"$(BUSTED)" --coverage --coverage-config-file=spec/quality/luacov.config \
		--seed=1 --sort \
		$(BUSTED_PATHS) spec/unit spec/integration
	@"$(LUACOV)" -c spec/quality/luacov.config
	@"$(PYTHON)" -m unittest spec.quality.test_coverage_gate -v
	@"$(PYTHON)" spec/quality/coverage_gate.py \
		--report build/quality/luacov.report.out \
		--baseline spec/quality/coverage-baseline.json

test-stress: check-lua
	@mkdir -p build/quality
	@"$(LUA)" spec/quality/run_stress.lua

test-compatibility: check-python
	@"$(PYTHON)" -m unittest spec.compatibility.test_matrix -v
	@"$(PYTHON)" spec/compatibility/matrix.py

test-compatibility-live: check-python check-lua
	@test -n "$(COMPATIBILITY_ENTRY)" || { \
		echo "Set COMPATIBILITY_ENTRY to a checked-in compatibility matrix row" >&2; \
		exit 2; \
	}
	@mkdir -p build/compatibility
	@"$(PYTHON)" spec/compatibility/run.py \
		--entry "$(COMPATIBILITY_ENTRY)" \
		--lua "$(LUA)" \
		--report "build/compatibility/$(COMPATIBILITY_ENTRY).json"

test-unified-meta: check-busted check-python
	@"$(BUSTED)" $(BUSTED_PATHS) spec/unified/matcher_spec.lua \
		spec/unified/operation_spec.lua
	@"$(PYTHON)" spec/unified/run_schema_meta.py --lua "$(LUA)"

test-unified-execution: check-python
	@"$(PYTHON)" spec/unified/run.py

lint: check-luacheck
	@"$(LUACHECK)" src spec

rockspec: check-luarocks
	@"$(LUAROCKS)" lint "$(ROCKSPEC)"

planning-check: check-python
	@"$(PYTHON)" planning/update_plan.py check
