# Connect Lua 5.4 to MongoDB and run `ping`

This five-minute example installs the public `mongodb` rock, starts one local
MongoDB server, runs the smallest complete command, and closes the client. It
uses stock Lua 5.4 with 64-bit integers. Lua 5.5, LuaJIT, and OpenResty are not
currently supported.

The program follows this lifecycle:

```text
load installed rock → enter Copas scheduler → connect → ping → close
```

## Requirements

- Stock Lua 5.4 with a 64-bit `lua_Integer`.
- LuaRocks configured for Lua 5.4.
- Docker with Docker Compose v2, or another reachable MongoDB deployment.

LuaRocks installs the driver's compatible Copas 4.11.x and other dependencies.
Do not install or upgrade Copas separately for this example.

## Install and run on macOS or Linux

Run these commands from this directory:

```sh
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27017/lua_examples_ping"
lua main.lua
diff -u expected-output.txt <(lua main.lua)
```

If the `lua` command resolves to another version, invoke your Lua 5.4 binary
instead (often `lua5.4`) and evaluate
`luarocks --lua-version=5.4 path` in your shell when LuaRocks uses a user-local
tree.

## Install and run on PowerShell

Run these commands from this directory:

```powershell
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
$env:MONGODB_URI = "mongodb://127.0.0.1:27017/lua_examples_ping"
lua .\main.lua
Compare-Object (Get-Content .\expected-output.txt) (lua .\main.lua)
```

`Compare-Object` prints nothing when the output matches.

## Expected output

[`expected-output.txt`](expected-output.txt) contains:

```text
MongoDB driver 0.5.0 or later loaded from LuaRocks
Ping succeeded
Client closed
```

The program uses `MONGODB_URI` when set and otherwise uses the Compose URI. It
creates one client inside `mongodb.run`, sends an ordered BSON command to the
`admin` database, reports operational failures through the driver's
`nil, err` contract, and closes the client before returning.

## Common failures

- **`lua-mongodb requires Lua 5.4`:** `lua` is Lua 5.5 or LuaJIT. Select the
  Lua 5.4 executable and confirm `luarocks ... config lua_version` prints 5.4.
- **Server selection or connection refused:** wait for
  `docker compose ps` to report `healthy`, then verify `MONGODB_URI` uses port
  27017.
- **No default database is configured:** include `/lua_examples_ping` in a
  custom URI. This example uses `admin` for `ping`, but later collection
  examples use the URI's default database.

## Cleanup

Remove the container and its example-only data volume:

```sh
docker compose down -v
```
