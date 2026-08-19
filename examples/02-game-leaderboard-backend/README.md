# Build a Server-Side Game Leaderboard with Lua and MongoDB

This example is a **dedicated backend process running stock Lua 5.4**. It is
not code that connects directly to MongoDB from LÖVE, Roblox, or another game
client. A production game would send authenticated requests to a service like
this one rather than distribute database credentials to players.

The deterministic workflow creates five evolving player profiles, submits a
score, awards an achievement, reads the top three, and aggregates the current
season. The next vertical slice adds an atomic credit transfer.

## What it demonstrates

- Ordered BSON player documents and explicit BSON arrays.
- A unique `player_id` index.
- `$max`, `$inc`, `$push`, `$set`, and `$addToSet` profile updates.
- Stable ranking with a compound sort and limit.
- Season reporting through `$match` and `$group`.
- BSON integer conversion through `to_number()`.
- Explicit `nil, err`, cursor, and client handling.
- A single-member replica set that becomes ready automatically.

## Requirements

- Stock Lua 5.4 with a 64-bit `lua_Integer`.
- LuaRocks configured for Lua 5.4.
- Docker with Docker Compose v2, or another reachable replica set.

LuaRocks installs the compatible Copas 4.11.x dependency. Do not separately
upgrade Copas for this example.

## Run on macOS or Linux

Run from this directory:

```sh
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27019/lua_examples_leaderboard?replicaSet=rs0"
lua seed.lua
lua main.lua
{ lua seed.lua; lua main.lua; } > actual-output.txt
diff -u expected-output.txt actual-output.txt
```

The Compose health check initiates `rs0` and waits for its primary election;
there is no manual replica-set command. Use your Lua 5.4 executable name in
place of `lua` when necessary.

## Run on PowerShell

```powershell
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
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

[`main.lua`](main.lua) demonstrates this lifecycle:

```text
connect → submit score → award achievement → rank → aggregate season → close
```

The score submission uses `$max` so a lower score cannot replace the player's
high score, while `$inc` records the season contribution. The ranking adds a
name tiebreaker, making its output stable even when scores match.

## Cleanup

```sh
docker compose down -v
```
