const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

const assert = std.debug.assert;

const conn = @import("connection.zig");
const Connection = conn.Connection;

pub const PhantomError = error{
UnsupportedSystem
};

pub const Result = struct {
    socket_path: []const u8,
    id: i96,
};

const Config = struct {
    dir: []const u8,
    temp_dir: []const u8,
    in_memory: bool,
};

pub const Phantom = struct {
    allocator: Allocator,
    io: Io,

    config: Config,
    os_tag: std.Target.Os.Tag,

    connections: std.hash_map.HashMap(i96, *Connection, std.hash_map.AutoContext(i96), 80),

    pub fn init(allocator: Allocator, io: Io, config: Config) @This() {
        assert(config.dir.len > 0);
        assert(config.temp_dir.len > 0);

        const phantom = Phantom{
            .allocator = allocator,
            .io = io,
            .config = config,
            .os_tag = switch (builtin.os.tag) {
                .macos => .macos,
                .linux => .linux,
                else => return PhantomError.UnsupportedSystem
            }
        };

        return phantom;
    }

    pub fn deinit(self: *@This()) void {
        _ = self;
    }

    pub fn spawn(self: *@This()) !Result {
        var connection = Connection.init(self.allocator, self.io, .{
            .dir = self.config.dir,
            .temp_dir = self.config.temp_dir,
            .os_tag = self.os_tag,
        });

        try self.connections.put(connection.id, &connection);

        const socket_path = try &connection.boot();
        
        return Result{
            .id = connection.id,
            .socket_path = socket_path,
        };
    }
};


test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
