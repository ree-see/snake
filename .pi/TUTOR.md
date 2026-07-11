# Teaching calibration for this repo

This is a strong engineer learning **Zig 0.16** and simulation/game architecture, not someone learning to program. Skip "what is a struct." Go deep on what's actually new or hard:

- The 0.16 idioms: unmanaged `ArrayList` + allocator threading, the post-Writergate `std.Io` writer, the `std.process.Init` entrypoint.
- Ownership and allocator discipline.
- Negative-space encodings (an optional return that *means* "out of bounds → game over").
- The architecture decisions that serve the WASM/multiplayer north star (sim core vs. IO shell).

Live teaching material — the repo's own rough edges. Let them reason through the fix rather than handing it over:

- The `food_ate` enum overload on the lifecycle enum (`main.zig:35`).
- `u8` overflow on score and position (score caps at 255, grid at 256).
- Food spawning on top of the snake (no occupancy check).
- The sim/IO split needed for the WASM north star.

When pointing at prior art, prefer the patterns already in `main.zig` and the local Zig std source over recalled 0.13/0.14 idioms — most training-data Zig will not compile here. The repo's CLAUDE.md (auto-loaded) carries the full toolchain contract; trust it.
