# Build a LuaRocks package explorer with Lua 5.4 or Lua 5.5 and MongoDB

This example uses a fixed catalog of eight familiar LuaRocks packages. MongoDB
cannot infer document order or array intent from arbitrary Lua tables, so the
code builds BSON documents and arrays explicitly.

The checked-in data is an example dataset, not a live or historical LuaRocks
API export. Every run starts with the same eight rows.

## What you'll do

- Load `mongodb` 0.5.0 or later from LuaRocks.
- Build ordered package documents with `mongodb.bson.document`.
- Build dense labels, versions, and dependencies with
  `mongodb.bson.array`.
- Create a unique index on `name`.
- Reset and insert the fixture idempotently.
- Look up one package and query a nested release field.
- Query array membership to find packages labelled `networking`.
- Update release metadata with `$set` and `$push`.
- Run an aggregation pipeline to rank shared dependencies.
- Iterate sorted cursors and close owned resources.

The programs run these steps:

```text
connect → obtain collection → list → lookup → query → update → aggregate → close
```

## Run on macOS or Linux

```sh
LUA_VERSION=5.5 # use 5.4 when that is your installed runtime
lua -v
luarocks --lua-version="$LUA_VERSION" config lua_version
luarocks --lua-version="$LUA_VERSION" install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27018/lua_examples_packages"
lua seed.lua
lua main.lua
{ lua seed.lua; lua main.lua; } > actual-output.txt
diff -u expected-output.txt actual-output.txt
```

Use the Lua executable that matches `LUA_VERSION` in place of `lua` when
necessary. LuaRocks installs the compatible Copas 4.11.x dependency; do not
upgrade Copas separately for this tutorial.

## Run on PowerShell

```powershell
$env:LUA_VERSION = "5.5" # use 5.4 when that is your installed runtime
lua -v
luarocks --lua-version=$env:LUA_VERSION config lua_version
luarocks --lua-version=$env:LUA_VERSION install mongodb
docker compose up -d --wait
$env:MONGODB_URI = "mongodb://127.0.0.1:27018/lua_examples_packages"
lua .\seed.lua
lua .\main.lua
```

Compare the combined output with [`expected-output.txt`](expected-output.txt).
Running `seed.lua` again deletes only this example's package documents and
recreates the same eight rows; it does not drop the database or index.

## BSON model

Each package has this shape:

```text
name
summary
uploader
license
labels[]
versions[] { version, released }
dependencies[]
download_count (BSON int64)
latest_release
```

[`packages.lua`](packages.lua) makes both container choices explicit. MongoDB
command documents need field order and BSON type identity, which a general Lua
table cannot supply reliably.

## Explore the catalog

[`main.lua`](main.lua) first lists the catalog, then performs four operations:

1. A `find_one` lookup retrieves Copas by package name.
2. Dot notation queries the nested release field `versions.version`.
3. An equality filter checks array membership against `labels`.
4. An aggregation pipeline unwinds `dependencies`, groups identical values,
   and sorts by popularity and name.

The aggregation count is a BSON integer value. The example calls
`to_number()` before Lua arithmetic instead of relying on implicit conversion.

Between the reads and aggregation, `update_one` adds a release document and
changes `latest_release`. Run `seed.lua` before `main.lua` to reset the example
and keep the modified count and output deterministic.

Both programs handle the driver's `value` or `nil, err` contract. On failure,
they close the active cursor and client before reporting the error. Exhausted
cursors close automatically. `main.lua` checks `is_closed()` before closing a
cursor early.

## Cleanup

```sh
docker compose down -v
```
