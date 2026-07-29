const std = @import("std");
const core = @import("core");
pub const Br = @import("Br.zig");
pub const Tron = @import("Tron.zig");
pub const Classic = @import("Classic.zig");

/// Lifecycle state shared by game variants and sessions.
pub const GameState = enum {
    lobby,
    running,
    paused,
    over,
};
