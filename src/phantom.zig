const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_darwin = native_os.isDarwin();
const is_linux = native_os == .linux;

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
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

pub const Phantom = struct {
    allocator: Allocator,
    io: Io,

    source_file_path: []const u8,
    dest_path: []const u8,

    connections: std.hash_map.HashMap(i96, *Connection, std.hash_map.AutoContext(i96), 80),

    /// Creates sub dirs for data and sockets, main temperary dir must exist.
    pub fn init(allocator: Allocator, io: Io, source_file_path: []const u8, dest_path: []const u8) PhantomError!@This() {
        assert(source_file_path.len > 0);
        assert(dest_path.len > 0);

        if (!is_darwin and !is_linux) {
            return PhantomError.UnsupportedSystem;
        }

        var cwd = Io.Dir.cwd();
        var file = cwd.openFile(io, source_file_path, .{
            .mode = .read_only
        }) catch |err| return switch (err) {
            Io.Dir.OpenError.FileNotFound => PhantomError.TemplateFileNotFound,
            else => PhantomError.UnexpectedError,
        };
        defer file.close(io);

        var dir = cwd.openDir(io, dest_path, .{}) catch |err| return switch (err) {
            Io.Dir.OpenError.FileNotFound => PhantomError.TemplateFileNotFound,
            else => PhantomError.UnexpectedError,
        };
        defer dir.close(io);

        try createDir(dir, io, "data");
        try createDir(dir, io, "socket");

        const phantom = Phantom{
            .allocator = allocator,
            .io = io,
            .source_file_path = source_file_path,
            .dest_path = dest_path,
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

    pub fn createDatabase(self: *@This()) !i96 {
        var connection = try Connection.init(
            self.allocator,
            self.io,
            self.source_file_path,
            self.dest_path);

        try self.connections.put(connection.id, &connection);

        return connection.id;
    }

    pub fn spawnChildProcess(self: *@This(), id: i96) !i96 {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .RUNNING) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        return try &connection.?.spawnProcess();
    }

    pub fn termChildProcess(self: *@This(), id: i96) !std.process.Child.Term {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .STOPPED) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        return try connection.?.killProcess(.TERM);
    }

    pub fn killChildProcess(self: *@This(), id: i96) !std.process.Child.Term {
        var connection = self.connections.get(id);

        if (connection == null) {
            return PhantomError.UnknownId;
        }

        if (connection.?.status == .STOPPED) {
            return PhantomError.ConnectionAlreadyRunning;
        }

        return try connection.?.killProcess(.KILL);
    }

    fn createDir(dir: Io.Dir, io: Io, sub_path: []const u8) PhantomError!void {
        dir.createDir(io, sub_path, Io.File.Permissions.default_dir) catch |err| switch (err) {
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
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest_path = try fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer allocator.free(dest_path);

    var phantom = try Phantom.init(allocator, io, "./test/template.db", dest_path);
    defer phantom.deinit();

    var data_dir = try tmp_dir.dir.openDir(io, "data", .{});
    defer data_dir.close(io);

    var socket_dir = try tmp_dir.dir.openDir(io, "socket", .{});
    defer socket_dir.close(io);
}

// test "fuzz example" {
//     try std.testing.fuzz({}, testOne, .{});
// }
//
// fn testOne(context: void, smith: *std.testing.Smith) !void {
//     _ = context;
//     // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
//
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(u8) = .empty;
//     defer list.deinit(gpa);
//     while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
//         .add_data => {
//             const slice = try list.addManyAsSlice(gpa, smith.value(u4));
//             smith.bytes(slice);
//         },
//         .dup_data => {
//             if (list.items.len == 0) continue;
//             if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
//             const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
//             const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
//             try list.appendSlice(gpa, list.items[off..][0..len]);
//             try std.testing.expectEqualSlices(
//                 u8,
//                 list.items[off..][0..len],
//                 list.items[list.items.len - len ..],
//             );
//         },
//     };
// }
