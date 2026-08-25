# Build a server-side game leaderboard with Lua and MongoDB

This example is a dedicated backend process running stock Lua 5.4 or Lua 5.5.
It does not connect to MongoDB from LÖVE, Roblox, or another game client. A
production game should send authenticated requests to a backend like this one
instead of distributing database credentials to players.

The sample seeds five player profiles. It submits a score, awards an
achievement, reads the top three, aggregates the current season, and transfers
credits atomically.

## What you'll build

- Ordered BSON player documents and explicit BSON arrays.
- A unique `player_id` index.
- `$max`, `$inc`, `$push`, `$set`, and `$addToSet` profile updates.
- Stable ranking with a compound sort and limit.
- Season reporting through `$match` and `$group`.
- A callback transaction that debits and credits two player profiles.
- BSON integer conversion through `to_number()`.
- Explicit `nil, err`, cursor, and client handling.
- A single-member replica set that becomes ready automatically.

## Requirements

- Stock Lua 5.4 or Lua 5.5 with a 64-bit `lua_Integer`.
- LuaRocks configured for the same Lua version as the executable.
- Docker with Docker Compose v2, or another reachable replica set.

LuaRocks installs the compatible Copas 4.11.x dependency. Do not separately
upgrade Copas for this example.

## Run on macOS or Linux

Run from this directory:

```sh
LUA_VERSION=5.5 # use 5.4 when that is your installed runtime
lua -v
luarocks --lua-version="$LUA_VERSION" config lua_version
luarocks --lua-version="$LUA_VERSION" install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27019/lua_examples_leaderboard?replicaSet=rs0"
lua seed.lua
lua main.lua
{ lua seed.lua; lua main.lua; } > actual-output.txt
diff -u expected-output.txt actual-output.txt
```

The Compose health check initiates `rs0` and waits for its primary election;
there is no manual replica-set command. Use the Lua executable that matches
`LUA_VERSION` in place of `lua` when necessary.

## Run on PowerShell

```powershell
$env:LUA_VERSION = "5.5" # use 5.4 when that is your installed runtime
lua -v
luarocks --lua-version=$env:LUA_VERSION config lua_version
luarocks --lua-version=$env:LUA_VERSION install mongodb
docker compose up -d --wait
$env:MONGODB_URI = "mongodb://127.0.0.1:27019/lua_examples_leaderboard?replicaSet=rs0"
lua .\seed.lua
lua .\main.lua
```

Compare the combined output with [`expected-output.txt`](expected-output.txt).
Run `seed.lua` before each demonstration to restore scores, achievements, and
credit balances.

## Data model and workflow

Each profile owns a stable player id, display name, high score, season score,
credit balance, achievements array, recent-match array, and update marker.
[`players.lua`](players.lua) keeps the fixture local so the example does not
depend on a game platform or external API.

[`main.lua`](main.lua) runs these steps:

```text
connect → submit score → award → rank → aggregate → transact → close
```

The score submission uses `$max` so a lower score cannot replace the player's
high score, while `$inc` records the season contribution. The ranking adds a
name tiebreaker, so equal scores still have a stable order.

## Transactional credit transfer

The final operation transfers 25 credits from Ada to Lin with
`session:with_transaction`. Both `update_one` calls receive the callback's
active session, so the debit and credit commit or abort together. The debit
filter also requires a sufficient balance.

The callback performs only database operations and is safe to run more than once.
The transaction API may rerun it after a `TransientTransactionError`; an
unknown commit result retries only the commit. Do not send email, award an
external prize, or perform another non-transactional side effect inside the
callback.

`with_transaction` owns commit, abort, and specification-required retries.
The application still owns cleanup. `main.lua` calls `end_session` whether the
transaction succeeds or returns an operational error, then closes the client.
Transactions require a replica set or sharded deployment. They do not work on
a standalone MongoDB server.

## Cleanup

```sh
docker compose down -v
```
