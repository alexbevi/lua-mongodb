# MongoDB Lua driver examples

These examples show how to build complete MongoDB applications with stock Lua
5.4 or Lua 5.5. Each directory includes its MongoDB environment, fixture data,
program, expected output, and cleanup instructions. The programs load the
released `mongodb` rock. They never add this checkout's `src/` directory to
`package.path`.

## Compatibility

| Environment | Status |
| --- | --- |
| Stock Lua 5.4 or Lua 5.5 with 64-bit integers | Required |
| `mongodb` rock 0.5.0 or later | Required; install the latest public rock |
| Copas 4.11.x | Installed by LuaRocks; do not upgrade it separately |
| LuaJIT and OpenResty | Not currently supported by the driver |
| MongoDB standalone | Used by the introductory examples |
| MongoDB replica set | Required by transactions and change streams |

Docker Compose v2 starts the local MongoDB environments. To use an existing
deployment instead, set the example's `MONGODB_URI`.

## Learning path

1. [`00-connect-and-ping`](00-connect-and-ping/README.md). Install the rock,
   connect to a standalone server, run `ping`, handle errors, and close the
   client.
2. [LuaRocks package explorer](01-luarocks-package-explorer/README.md). Model
   BSON documents and arrays, then seed, query, update, and aggregate a fixed
   package catalog.
3. [Game leaderboard backend](02-game-leaderboard-backend/README.md). Build a
   stock-Lua backend with rankings, achievements, season reports, and a
   transaction.
4. [Pong using change streams](03-pong-game-using-changestreams/README.md).
   Play a two-window LÖVE game whose stock-Lua bridges synchronize state
   through MongoDB change streams.

Start with example 00. The later READMEs repeat their installation and run
commands, so each example also works on its own.
