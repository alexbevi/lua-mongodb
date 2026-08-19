# Build a LuaRocks Package Explorer with Lua 5.4 and MongoDB

This example starts with a deterministic catalog of eight familiar LuaRocks
packages. It shows why MongoDB values are not arbitrary Lua tables: BSON keeps
documents ordered and distinguishes documents from arrays of labels, versions,
and dependencies.

The checked-in data is a small illustrative snapshot, not a live or historical
LuaRocks API export. Keeping it local makes every run reproducible.

## What this example demonstrates

- Loading `mongodb` 0.5.0 or later from LuaRocks.
- Building ordered package documents with `mongodb.bson.document`.
- Building dense labels, versions, and dependencies with
  `mongodb.bson.array`.
- Creating a unique index on `name`.
- Resetting and inserting a fixture idempotently.
- Looking up one package and querying a nested release field.
- Querying array membership to find packages labelled `networking`.
- Updating release metadata with `$set` and `$push`.
- Running an aggregation pipeline to rank shared dependencies.
- Iterating sorted cursors and closing owned resources.

The solution follows a normal application lifecycle:

```text
connect → obtain collection → list → lookup → query → update → aggregate → close
```

## Run on macOS or Linux

```sh
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27018/lua_examples_packages"
lua seed.lua
lua main.lua
{ lua seed.lua; lua main.lua; } > actual-output.txt
diff -u expected-output.txt actual-output.txt
```

Use your Lua 5.4 executable name in place of `lua` when necessary. LuaRocks
installs the compatible Copas 4.11.x dependency; do not upgrade Copas
separately for this tutorial.

## Run on PowerShell

```powershell
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
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

[`packages.lua`](packages.lua) makes both container choices visible. This is
important for application code and for MongoDB command documents, where field
order and BSON type identity cannot be inferred reliably from a general Lua
table.

## Explore the catalog

[`main.lua`](main.lua) first lists the catalog, then performs four distinct
operations:

1. A `find_one` lookup retrieves Copas by package name.
2. Dot notation queries the nested release field `versions.version`.
3. An equality filter demonstrates array membership against `labels`.
4. An aggregation pipeline unwinds `dependencies`, groups identical values,
   and sorts by popularity and name.

The aggregation count is a BSON integer value. The example calls
`to_number()` before using it as a Lua number, another small but important
boundary between BSON and general Lua values.

Between the reads and aggregation, `update_one` adds a release document and
changes `latest_release`. Run `seed.lua` before `main.lua` to reset the example
and keep the modified count and output deterministic.

Both programs handle the driver's `value` or `nil, err` contract explicitly.
On a failure, the active cursor and client are closed before the error is
reported. Exhausted cursors close automatically; `main.lua` checks
`is_closed()` before closing a cursor early.

## Cleanup

```sh
docker compose down -v
```
