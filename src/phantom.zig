const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

const assert = std.debug.assert;

const conn = @import("connection.zig");
const Connection = conn.Connection;

const SpawnError = conn.SpawnError;
const KillError = conn.KillError;

pub const PhantomError = error{
UnsupportedSystem,
TemplateFileNotFound,
TempDirNotFound,
PermissionDenied,
CreateDirError,
UnexpectedError
} || Allocator.Error;

const Config = struct {
    template_file_path: []const u8,
    temp_dir_path: []const u8,
    in_memory: bool,
};

pub const Phantom = struct {
    allocator: Allocator,
    io: Io,

    config: Config,
    os_tag: std.Target.Os.Tag,

    connections: std.hash_map.HashMap(i96, *Connection, std.hash_map.AutoContext(i96), 80),

    /// Creates sub dirs for data and sockets, main temperary dir must exist.
    pub fn init(allocator: Allocator, io: Io, config: Config) PhantomError!@This() {
        assert(config.template_file_path.len > 0);
        assert(config.temp_dir_path.len > 0);

        var file = Io.Dir.openFile(Io.Dir.cwd(), io, config.template_file_path, .{
            .mode = .read_only
        }) catch |err| return switch (err) {
            Io.Dir.OpenError.FileNotFound => PhantomError.TemplateFileNotFound,
            else => PhantomError.UnexpectedError,
        };
        defer file.close(io);

        const data_dir_path = std.fmt.allocPrint(allocator, "{s}/data", .{ config.temp_dir_path }) catch { return PhantomError.OutOfMemory; };
        defer allocator.free(data_dir_path);

        try createDir(Io.Dir.cwd(), io, data_dir_path);

        const socket_dir_path = std.fmt.allocPrint(allocator, "{s}/socket", .{ config.temp_dir_path }) catch { return PhantomError.OutOfMemory; };
        defer allocator.free(socket_dir_path);

        try createDir(Io.Dir.cwd(), io, socket_dir_path);

        const phantom = Phantom{
            .allocator = allocator,
            .io = io,
            .config = config,
            .os_tag = switch (builtin.os.tag) {
                .macos => .macos,
                .linux => .linux,
                else => return PhantomError.UnsupportedSystem
            },
            .connections = .init(allocator)
        };

        return phantom;
    }

    pub fn deinit(self: *@This()) void {
        var it = self.connections.iterator();

        while (it.next()) |kv| {
            var connection = kv.value_ptr.*;
            connection.deinit();
        }

        self.connections.deinit();
    }

    pub fn setup(self: *@This()) !i96 {
        var connection = Connection.init(self.allocator, self.io, .{
            .template_file = self.config.template_file_path,
            .temp_dir = self.config.temp_dir_path,
            .os_tag = self.os_tag,
        });

        try self.connections.put(connection.id, &connection);
    }

    pub fn spawn(self: *@This(), id: i96) !i96 {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .RUNNING) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        const socket_path = try &connection.?.boot();
        
        return socket_path;
    }

    pub fn term(self: *@This(), id: i96) !std.process.Child.Term {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .STOPPED) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        return try connection.?.kill(.TERM);
    }

    pub fn kill(self: *@This(), id: i96) !std.process.Child.Term {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .STOPPED) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        return try connection.?.kill(.KILL);
    }

    fn createDir(dir: Io.Dir, io: Io, sub_path: []const u8) PhantomError!void {
        Io.Dir.createDir(dir, io, sub_path, Io.File.Permissions.default_dir) catch |err| switch (err) {
            Io.Dir.CreateDirError.AccessDenied => return PhantomError.PermissionDenied,
            Io.Dir.CreateDirError.PermissionDenied => return PhantomError.PermissionDenied,
            Io.Dir.CreateDirError.PathAlreadyExists => {},
            Io.Dir.CreateDirError.FileNotFound => return PhantomError.TempDirNotFound,
            Io.Dir.CreateDirError.ReadOnlyFileSystem => return PhantomError.PermissionDenied,
            else => return PhantomError.CreateDirError,
        };
    }
};

const testing = std.testing;

test "phantom: init" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var phantom = try Phantom.init(gpa, io, .{
        .template_file = "./test",
        .temp_dir = tmp_dir,
        .in_memory = false,
    });
    defer phantom.deinit();

    var dir = try Io.Dir.openDir(Io.Dir.cwd(), io, tmp_dir, .{});
    defer dir.close(io);

    var data_dir = try dir.openDir(io, "data", .{});
    defer data_dir.close(io);

    var socket_dir = try dir.openDir(io, "socket", .{});
    defer socket_dir.close(io);
}

test "phantom: from cwd" {
    const gpa = testing.allocator;
    const io = testing.io;

    const temp_dir = "./phantom";

    var phantom = try Phantom.init(gpa, io, .{
        .template_file_path = "./test",
        .temp_dir_path = temp_dir,
        .in_memory = false,
    });
    defer phantom.deinit();

    var dir = try Io.Dir.openDir(Io.Dir.cwd(), io, temp_dir, .{});
    defer dir.close(io);

    var data_dir = try dir.openDir(io, "data", .{});
    defer data_dir.close(io);

    var socket_dir = try dir.openDir(io, "socket", .{});
    defer socket_dir.close(io);
}

test "phantom: no template_file" {
}

test "phantom: no temp_dir" {
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
