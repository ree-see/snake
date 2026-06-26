# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Classic Snake game rendered as a terminal UI, written in Zig. North star: evolve this into a **snake.io-style multiplayer game compiled to WASM**, embedded on a portfolio site so visitors can play in-browser. The current code is the single-player TUI starting point; assume changes should move toward a separable, WASM-compilable simulation core (see Architecture).

## Toolchain — Zig 0.16 (read before writing any Zig)

This targets **Zig 0.16.0** and uses the post-"Writergate" `std.Io` interface plus the new program entrypoint. Most Zig idioms from training data are from 0.13/0.14 and **will not compile here**. Match the patterns already in `main.zig`:

- **Entrypoint:** `pub fn main(init: std.process.Init) !void`. Get IO and allocator from `init` (`const io = init.io;`). There is no argless `main`.
- **Unmanaged ArrayList:** create with `std.ArrayList(T).empty`; pass the allocator to every mutating call — `.append(gpa, x)`, `.insert(gpa, 0, x)`, `.deinit(gpa)`. `.pop()` takes no allocator. Do **not** use the old managed `std.ArrayList(T).init(allocator)` API.
- **Writers:** `std.Io.File.stdout().writer(io, &buf)` gives a file writer; its `.interface` field is the generic writer you `.print(...)` / `.flush()` on. Buffer is caller-owned (`var buf: [N]u8 = undefined;`).
- **Time/seed:** `std.Io.Clock.awake.now(io).nanoseconds`.
- Terminal control still goes through `std.posix` (termios/raw mode) and `std.c.ioctl` (window size).

If unsure about a 0.16 API, prefer grepping `main.zig` or checking the local std source over recalling older signatures.

## Commands

No `build.zig` / `build.zig.zon` exists yet — this is a single-file build.

- **Run the game (interactive TUI):** `zig run main.zig` — opens an alternate screen; **ESC quits**. Movement keys are `i`/`j`/`k`/`l` = up/left/down/right (not WASD, not arrows).
- **Compile-check only (use this to verify changes; running blocks on the TUI loop):** `zig build-exe main.zig -femit-bin=<scratch>/snake`. Compiles clean with no `-lc` flag.
- **Tests:** none yet. Once `test {}` blocks are added, `zig test main.zig` runs them; filter a single test with `zig test main.zig --test-filter "<name substring>"`. Per the TDD mandate, the platform-agnostic core (`Snake.step`, `Snake.next`, `contains`, grid math) is the part to cover first — it needs no terminal.

## Architecture

**Source of truth vs. render buffer.** Game state lives in `Snake.body` (an ArrayList of `Position`, head at index 0) and `Food.pos`. `Grid` (fixed `64×32` array of `Cell`) is **not** authoritative — it is a scratch buffer that `render()` paints from snake+food each frame and then `clear()`s. Don't store gameplay state in `Grid`.

**The tick.** `Snake.step()` is the core simulation step and the place most game rules live: it computes the next head with `next()` (which returns `null` when the head would leave the grid → game over), rejects self-collision via `contains()`, inserts the new head at index 0, then either keeps the tail (returns `.food_ate`) or pops it (returns `.running`). Growth = "don't pop the tail this tick."

**Loop (`main`).** Raw mode (`enableRawMode`, restored via `defer`) + alternate screen + hidden cursor. `termios` is set to `VMIN=0`/`VTIME=2`, so `std.posix.read` is a non-blocking ~200ms-timeout poll — that read cadence *is* the game clock and the input poll at once. `setDirection` maps raw key bytes (105/106/107/108) to a `Direction` with a reverse-into-yourself guard.

**Rendering.** `render()` uses absolute ANSI cursor positioning (`\x1b[{row};{col}H`) and centers the board in the live terminal size (`termSize()` via `ioctl`). It deliberately avoids `\r` (carriage return), because `OPOST` is disabled in raw mode and `\r` would snap the cursor to column 0 and break centering (see the comment in `render`).

**Terminal coupling and the WASM path.** `main`, `render`, `enableRawMode`/`disableRawMode`, `termSize`, and the `std.posix`/`std.c` calls are terminal-only and cannot compile to `wasm32-freestanding`. The model types (`Position`, `Cell`, `Grid`, `Snake`, `Food`, `Direction`, `GameState`, and `Snake.step`/`next`/`contains`) are already close to platform-agnostic. The natural first step toward the WASM/.io goal is extracting that simulation core away from the I/O shell so it can be driven by both the TUI today and a browser/server frontend later.

## Known rough edges (intentional, not yet fixed)

- `GameState.food_ate` is overloaded onto the lifecycle enum; the author flagged it as a smell in-code (`main.zig:35`). Reconsider when refactoring the tick.
- `Position.x/y` and `Game.score` are `u8` — score overflows past 255, and positions cap the grid at 256.
- `Food.new` can spawn food on top of the snake (no occupancy check).
