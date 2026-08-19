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

The example includes both a deterministic headless proof and a playable
two-window LÖVE 11.5 frontend.

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

## Play the two-window demo

Install LÖVE 11.5, keep MongoDB and both bridge terminals running, then open
two more terminals from this example directory:

```sh
love client -- p1
```

```sh
love client -- p2
```

On macOS without a `love` shell command, use
`/Applications/love.app/Contents/MacOS/love client -- p1` and repeat it for
p2. On Windows, use the full path to `love.exe` when it is not on `PATH`.

- Player 1 moves with **W / S** and owns the authoritative ball simulation.
- Player 2 moves with **Up / Down** and owns only the right paddle.
- Escape closes the focused window.

Place the windows side by side. Moving either paddle writes through its local
stock-Lua bridge; both windows then render the `updateLookup` snapshot returned
by their MongoDB change stream. The local player is green, the remote player
is white, and the bottom panel exposes role, bridge connectivity, change event
count, last update age, resume-token availability, and render rate.

Clients publish at **20 Hz**, while LÖVE renders at the display frame rate and
interpolates remote state. Player 1 alone publishes ball and score fields; the
p2 bridge discards those fields even if a modified client sends them.
Snapshots with an older bridge sequence are ignored.

For the most compelling rejoin demonstration, move and score with both windows,
close p2, keep playing in p1, then **restart the p2 window** with
`love client -- p2`. Its first input re-registers the UDP peer, and the next
change event restores the current paddles, ball, and score without reseeding.

This is an educational visualization of driver coroutines, role-scoped writes,
change streams, `updateLookup`, and resumable state. It is
**not a production low-latency transport**: a real competitive game should use
an authoritative game server and a purpose-built network protocol, then persist
appropriate state to MongoDB.

## Cleanup

Stop the bridge processes, then remove the example database volume:

```sh
docker compose down -v
```
