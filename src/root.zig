const std = @import("std");
const Io = std.Io;

const phantom = @import("phantom.zig");

pub const Phantom = phantom.Phantom;
pub const PhantomError = phantom.PhantomError;
pub const SpawnError = phantom.SpawnError;
pub const KillError = phantom.KillError;

test "test:main:beforeAll" {
    std.testing.refAllDecls(@This());
}
