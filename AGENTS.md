# Snake

## Build And Test

- Requires Zig 0.16. `zig build` installs all three artifacts into `zig-out/bin/`: `game-server`, `snake`, and `snake-wasm.wasm`.
- `zig build test` runs the TUI, core, and session test targets. For a focused core test, use `zig test src/core.zig --test-filter "<name>"`.
- `zig build classic` starts the raw-mode TUI; `i`/`j`/`k`/`l` control movement and Esc exits. It links libc for terminal-size ioctl support.
- `zig build server` serves `web/` and accepts WebSocket connections at `http://localhost:8080/`; run it from the repository root because static paths are relative to the working directory.
- `zig build wasm` produces the freestanding `snake-wasm` module with no entry point and exported functions from `src/wasm.zig`.

## Architecture

- `src/core.zig` is the platform-agnostic simulation and its tests. It owns both `ClassicGame` and five-player `TronGame`; keep terminal, HTTP, and browser code out of it.
- `src/tui.zig` is the Classic Snake terminal shell. `Grid` is render scratch state only; `ClassicGame.snake`, `food`, and `state` are authoritative.
- `src/server.zig` serves static files and creates a detached thread per connection. `src/session.zig` owns the per-session game thread, player slots, synchronized input queue, and frame broadcasts.
- `src/wasm.zig` exposes a process-global `TronGame` to JavaScript. Keep its ABI exports and the browser code in `web/` synchronized when changing multiplayer state or delta encoding.

## Zig 0.16

- Entry points use `pub fn main(init: std.process.Init) !void`; obtain IO and allocators from `init`.
- Use unmanaged `std.ArrayList(T).empty` and pass the allocator to mutations. `TronGame.snakes` is a `std.MultiArrayList(Snake)`: deinitialize each snake body before deinitializing its columns.
- Use the post-Writergate `std.Io` writer interface (`writer(...).interface`) and `std.Io.Clock.awake` APIs. Verify unfamiliar APIs against local source instead of older Zig examples.
