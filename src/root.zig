const std = @import("std");
const Io = std.Io;

const phantom = @import("phantom.zig");
const reflink = @import("reflink.zig");

pub const Phantom = phantom.Phantom;
pub const PhantomError = phantom.PhantomError;

test "test:main:beforeAll" {
    std.testing.refAllDecls(@This());
}
