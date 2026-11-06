const std = @import("std");

const phantom = @import("phantom.zig");

pub const Phantom = phantom.Phantom;
pub const PhantomError = phantom.PhantomError;

test "test:main:beforeAll" {
    std.testing.refAllDecls(@This());
}
