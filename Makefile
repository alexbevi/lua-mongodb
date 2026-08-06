LUA ?= lua
LUAROCKS ?= luarocks
BUSTED ?= busted
LUACHECK ?= luacheck
PYTHON ?= python3

ROCKSPEC := lua-mongodb-scm-1.rockspec
BUSTED_PATHS := --lpath=src/?.lua --lpath=src/?/init.lua

.PHONY: check check-tools check-lua check-busted check-luacheck check-luarocks check-python \
	test-unit test-integration test-unified test-unified-schema test-unified-inventory \
	test-unified-meta test-unified-execution lint rockspec planning-check

check: test-unit test-integration test-unified lint rockspec planning-check

check-tools: check-lua check-busted check-luacheck check-luarocks check-python

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

test-unified-meta: check-busted check-python
	@"$(BUSTED)" $(BUSTED_PATHS) spec/unified/matcher_spec.lua
	@"$(PYTHON)" spec/unified/run_schema_meta.py --lua "$(LUA)"

test-unified-execution: check-python
	@"$(PYTHON)" spec/unified/run.py

lint: check-luacheck
	@"$(LUACHECK)" src spec

rockspec: check-luarocks
	@"$(LUAROCKS)" lint "$(ROCKSPEC)"

planning-check: check-python
	@"$(PYTHON)" planning/update_plan.py check
