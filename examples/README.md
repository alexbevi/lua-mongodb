# MongoDB Lua Driver Examples

These examples answer a practical question: **how do I build a complete
MongoDB application with stock Lua 5.4?** Each directory owns its MongoDB
environment, data, program, expected output, and cleanup instructions. The
programs load the released `mongodb` rock; they never add this checkout's
`src/` directory to `package.path`.

## Compatibility

| Environment | Status |
| --- | --- |
| Stock Lua 5.4 with 64-bit integers | Required |
| `mongodb` rock 0.5.0 or later | Required; install the latest public rock |
| Copas 4.11.x | Installed by LuaRocks; do not upgrade it separately |
| Lua 5.5 | Not currently supported |
| LuaJIT and OpenResty | Not currently supported by the driver |
| MongoDB standalone | Used by the introductory examples |
| MongoDB replica set | Required by transactions and change streams |

Docker Compose v2 provides the reproducible local environments. You may use
an existing MongoDB deployment by setting the example's `MONGODB_URI` instead.

## Learning path

1. [`00-connect-and-ping`](00-connect-and-ping/README.md) — install the rock,
   connect to a standalone server, run `ping`, handle errors, and close the
   client.
2. `01-luarocks-package-explorer` — model BSON documents and arrays, then
   seed, query, update, and aggregate a recognizable package catalog.
3. `02-game-leaderboard-backend` — build a dedicated Lua 5.4 backend with
   rankings, achievements, season reports, and a transaction.
4. `03-pong-game-using-changestreams` — play a two-window LÖVE game whose
   stock-Lua bridge processes synchronize state through MongoDB change
   streams.

Start with example 00. Every later README repeats the exact installation and
execution commands so it can be used independently.
