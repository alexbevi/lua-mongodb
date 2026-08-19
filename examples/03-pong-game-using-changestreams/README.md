# Play Pong through MongoDB Change Streams and Lua Coroutines

This example makes the driver's real-time path visible. Two game clients will
control separate LÖVE windows, while a **stock Lua 5.4 bridge** beside each
window owns MongoDB access. Client input crosses local UDP; MongoDB change
streams carry full match snapshots back to the bridges.

```text
LÖVE p1 ⇄ UDP ⇄ Lua 5.4 bridge p1 ⇄ MongoDB ⇄ Lua 5.4 bridge p2 ⇄ UDP ⇄ LÖVE p2
```

The checked-in [`client/protocol.lua`](client/protocol.lua) is Lua 5.1-compatible
and does not load the MongoDB driver. This is the deliberate
runtime boundary: LÖVE uses LuaJIT, while the driver requires stock Lua 5.4,
64-bit integers, and its Copas runtime.

This slice provides the bridge and a deterministic headless proof. The next
slice adds the playable two-window frontend.

## What the headless proof demonstrates

- A replica set that self-initiates with one Compose command.
- A real non-blocking-friendly LuaSocket UDP protocol boundary.
- Role ownership: p2 can update only `players.p2.paddle_y` and
  `players.p2.input_seq`; p1 additionally owns ball and score authority.
- A filtered collection change stream with `full_document = "updateLookup"`.
- A complete post-update match snapshot and retained resume token.
- Public LuaRock and isolated source-rock execution without `src/` path hacks.

## Install and run the headless proof

Run from this directory on macOS or Linux:

```sh
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
export MONGODB_URI="mongodb://127.0.0.1:27020/pong_demo?replicaSet=rs0"
export PONG_MATCH_ID="demo-match"
lua seed.lua
lua smoke.lua
{ lua seed.lua; lua smoke.lua; } > actual-output.txt
diff -u expected-output.txt actual-output.txt
```

PowerShell uses the same programs:

```powershell
lua -v
luarocks --lua-version=5.4 config lua_version
luarocks --lua-version=5.4 install mongodb
docker compose up -d --wait
$env:MONGODB_URI = "mongodb://127.0.0.1:27020/pong_demo?replicaSet=rs0"
$env:PONG_MATCH_ID = "demo-match"
lua .\seed.lua
lua .\smoke.lua
```

Compare the combined output with [`expected-output.txt`](expected-output.txt).
The smoke sends deliberately bogus ball and score values from p2. The bridge
ignores them, the change-stream `update_lookup` snapshot retains the original
ball and score, and the printed update paths prove the ownership boundary.

## Run the two bridge processes

After seeding, open two terminals in this directory:

```sh
lua run_bridge.lua p1
```

```sh
lua run_bridge.lua p2
```

The bridges listen on `127.0.0.1:27101` and `127.0.0.1:27102` respectively.
Each one cooperatively polls local UDP and `try_next()` on its filtered change
stream. Every returned event carries `fullDocument`; the bridge sends that
snapshot and resume-token availability to its local client.

## Cleanup

Stop the bridge processes, then remove the example database volume:

```sh
docker compose down -v
```
