const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_darwin = native_os.isDarwin();
const is_linux = native_os == .linux;

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const process = std.process;
const assert = std.debug.assert;

const fs = @import("fs.zig");
const reflink = @import("reflink.zig");

pub const PhantomError = error{
UnsupportedSystem,
TemplateFileNotFound,
PermissionDenied,
CreateDirError,
FileCopyError,
SockCreateError,
UnexpectedError
} || Allocator.Error;

pub const SpawnError = error{
Unable,
UnexpectedError,
} || process.SpawnError;

pub const KillError = error{
ProcessNotFound,
ProcessNotRunning,
PermissionDenied,
AccessDenied,
Canceled,
UnexpectedError,
};

const Status = enum(u8) {
    INITIALIZED,
    RUNNING,
    STOPPED,
    FAILED
};

const random_bytes_count = 12;
const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

pub const Phantom = struct {
    allocator: Allocator,

    sub_dir: fs.TmpDir,

    data_path: []const u8,
    socket_path: []const u8,

    status: Status,

    child: *process.Child,

    /// Creates sub dirs for data and sockets, main temperary dir must exist.
    pub fn init(allocator: Allocator, io: Io, source_path: []const u8, dest_path: []const u8) PhantomError!@This() {
        assert(source_path.len > 0);
        assert(dest_path.len > 0);

        if (!is_darwin and !is_linux) {
            return PhantomError.UnsupportedSystem;
        }

        var cwd = Dir.cwd();
        var file = cwd.openFile(io, source_path, .{
            .mode = .read_only
        }) catch |err| return switch (err) {
            Dir.OpenError.FileNotFound => PhantomError.TemplateFileNotFound,
            else => PhantomError.UnexpectedError,
        };
        file.close(io);

        const sub_dir = fs.tmpDir(io, dest_path) catch { return PhantomError.CreateDirError; };

        const data_path = try std.fmt.allocPrint(allocator, "{s}/data", .{ sub_dir.sub_path });
        const socket_path = try std.fmt.allocPrint(allocator, "{s}/sock", .{ sub_dir.sub_path });

        reflink.copyOnWrite(cwd, source_path, sub_dir.dir, "data", io, .{}) catch { return PhantomError.FileCopyError; };
        var sock_file = sub_dir.dir.createFile(io, "sock", .{ .truncate = true }) catch { return PhantomError.SockCreateError; };
        sock_file.close(io);

        return Phantom{
            .allocator = allocator,
            .sub_dir = sub_dir,
            .data_path = data_path,
            .socket_path = socket_path,
            .status = .INITIALIZED,
            .child = undefined,
        };
    }

    pub fn deinit(self: *@This(), io: Io) void {
        if (self.status == .RUNNING) {
            _ = self.killProcess(io, .KILL) catch |err| {
                // Assuming process is already killed
                if (err == KillError.ProcessNotFound) {
                    self.status = .STOPPED;
                    return;
                }

                const msg = std.fmt.allocPrint(self.allocator, "unable to kill process #{d}", .{ self.child.id.? }) catch {
                    @panic("unable to kill process");
                };

                @panic(msg);
            };
        }

        self.allocator.free(self.data_path);
        self.allocator.free(self.socket_path);

        self.sub_dir.cleanup(io);
    }

    pub fn spawnProcess(self: *@This(), io: Io) SpawnError![]const u8 {
        const argv = &[_][]const u8{
            "postgres",
            "-D",
            self.data_path,
            "-c",
            "unix_socket_directories=",
            self.socket_path,
            "-c",
            "listen_addresses=\"\"",
        };

        var child = try process.spawn(io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        self.child = &child;
        self.status = .RUNNING;

        return self.socket_path;
    }

    pub fn killProcess(self: *@This(), io: Io, sig: std.posix.SIG) KillError!process.Child.Term {
        if (self.child.id) |pid| {
            std.posix.kill(pid, sig) catch |err| return switch (err) {
                std.posix.KillError.PermissionDenied => KillError.PermissionDenied,
                std.posix.KillError.ProcessNotFound => KillError.ProcessNotFound,
                else => KillError.UnexpectedError,
            };
        } else {
            return KillError.ProcessNotRunning;
        }

        const term = self.child.wait(io) catch |err| {
            self.status = .FAILED;

            return switch (err) {
                process.Child.WaitError.AccessDenied => KillError.AccessDenied,
                process.Child.WaitError.Canceled => KillError.Canceled,
                else => KillError.UnexpectedError,
            };
        };

        self.status = .STOPPED;

        return term;
    }

    pub fn getPid(self: *@This()) ?process.Child.Id {
        return self.child.id;
    }

    fn createSubPath(io: Io, dir: Dir) !Dir {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        return try dir.createDirPathOpen(io, &sub_path, .{ .open_options = .{} });
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
    defer phantom.deinit(io);

    var data_file = try tmp_dir.dir.openFile(io, phantom.data_path, .{});
    defer data_file.close(io);
}

test "phantom: spawn" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest_path = try fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer allocator.free(dest_path);

    var phantom = try Phantom.init(allocator, io, "./test/template.db", dest_path);
    defer phantom.deinit(io);

    _ = try phantom.spawnProcess(io);
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
