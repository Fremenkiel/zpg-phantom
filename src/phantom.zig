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
const Thread = std.Thread;
const posix = std.posix;
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

pub const KillError = error{
ProcessNotFound,
ProcessNotRunning,
PermissionDenied,
AccessDenied,
Canceled,
UnexpectedError,
};

pub const CheckHealthError = error{
PostgresExitedUnexpectedly,
PostgresCrashed,
PostgresAbnormalTermination
} || process.Child.WaitError;

pub const WaitUntilReadyError = CheckHealthError || Io.Cancelable;

pub const SpawnError = error{
ProcessAlreadyExist,
UnexpectedStatus,
UnexpectedError,
} || process.SpawnError || Io.ConcurrentError || WaitUntilReadyError;

const Status = enum(u8) {
    Initialized,
    Running,
    Stopped,
    Terminated,
    Failed
};

const random_bytes_count = 12;
const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

const pg_ready_str = "database system is ready to accept connections";

pub const Phantom = struct {
    allocator: Allocator,
    io: Io,

    child: ?process.Child = null,
    mutex: Io.Mutex = .init,

    ready_event: Io.Event = .unset,
    exited_event: Io.Event = .unset,

    sub_dir: fs.TmpDir,
    data_path: []const u8,
    socket_path: []const u8,

    status: Status,
    term_result: ?process.Child.Term = null,
    wait_err: ?process.Child.WaitError = null,

    stderr_future: ?Io.Future(void) = null,
    monitor_future: ?Io.Future(void) = null,

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
        reflink.copyOnWrite(cwd, source_path, sub_dir.dir, "data", io, .{}) catch { return PhantomError.FileCopyError; };

        const data_path = try std.fmt.allocPrint(allocator, "{s}/{s}/data", .{ dest_path, sub_dir.sub_path });
        errdefer allocator.free(data_path);

        const socket_path = try std.fmt.allocPrint(allocator, "{s}/sock", .{ data_path });
        errdefer allocator.free(socket_path);

        sub_dir.dir.createDir(io, "data/sock", .default_dir ) catch return PhantomError.SockCreateError;

        return Phantom{
            .allocator = allocator,
            .io = io,
            .sub_dir = sub_dir,
            .data_path = data_path,
            .socket_path = socket_path,
            .status = .Initialized,
        };
    }

    fn createSubPath(io: Io, dir: Dir) Dir.CreateDirPathOpenError!Dir {
        var random_bytes: [random_bytes_count]u8 = undefined;
        io.random(&random_bytes);
        var sub_path: [sub_path_len]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

        return try dir.createDirPathOpen(io, &sub_path, .{ .open_options = .{} });
    }

    pub fn deinit(self: *@This()) void {
        if (self.status == .Running) {
            self.kill(.TERM) catch |err| {
                // Assuming process is already killed
                if (err == KillError.ProcessNotFound) {
                    self.status = .Stopped;
                    return;
                }

                @panic("unable to kill process");
            };
        }

        self.allocator.free(self.data_path);
        self.allocator.free(self.socket_path);

        self.sub_dir.cleanup(self.io);

        if (self.monitor_future) |*fut| {
            fut.cancel(self.io);
        }

        if (self.stderr_future) |*fut| {
            fut.cancel(self.io);
        }
    }

    pub fn spawn(self: *@This()) SpawnError!void {
        if (self.child != null) return SpawnError.ProcessAlreadyExist;
        if (self.status == .Running) return SpawnError.UnexpectedStatus;

        const argv = &[_][]const u8{ "postgres", "-D", self.data_path, "-k", "./sock", "-c", "listen_addresses=", };

        self.child = try process.spawn(self.io, .{
            .argv = argv,
            .stdout = .inherit,
            .stderr = .pipe,
        });

        self.status = .Running;
        self.exited_event = .unset;

        self.ready_event.reset();
        self.exited_event.reset();

        self.stderr_future = try self.io.concurrent(drainStderr, .{self});
        self.monitor_future = try self.io.concurrent(monitorLoop, .{self});

        try self.waitUntilReady();
    }

    fn drainStderr(self: *@This()) void {
        if (self.child == null) return;

        var buffer: [1024]u8 = undefined;
        var reader = self.child.?.stderr.?.reader(self.io, &buffer);
        var r = &reader.interface;

        while (true) {
            const maybe_line = r.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = r.discardDelimiterInclusive('\n') catch break;
                    continue;
                },
                else => break,
            };

            const line = maybe_line orelse break;

            // ensure fatal entries are logged to the user
            if (std.mem.indexOf(u8, line, "FATAL") != null) {
                std.log.err("[pg] {s}", .{line});
            } else {
                std.log.debug("[pg] {s}", .{line});
            }

            if (!self.ready_event.isSet()) {
                if (std.mem.indexOf(u8, line, pg_ready_str) != null) {
                    self.ready_event.set(self.io);
                }
            }
        }
    }

    fn monitorLoop(self: *@This()) void {
        if (self.child == null) return;
        const term_or_err = self.child.?.wait(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (term_or_err) |term| {
            self.status = .Terminated;
            self.term_result = term;
        } else |err| {
            self.status = .Failed;
            self.wait_err = err;
        }

        self.exited_event.set(self.io);
        self.ready_event.set(self.io);
    }

    fn waitUntilReady(self: *@This()) WaitUntilReadyError!void {
        try self.ready_event.wait(self.io);

        try self.checkHealth();
    }

    pub fn checkHealth(self: *@This()) CheckHealthError!void {
        if (!self.exited_event.isSet()) return;

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        if (self.status == .Stopped) return;
        if (self.wait_err) |err| return err;

        if (self.term_result) |term| {
            switch (term) {
                .exited => |code| {
                    std.log.err("Postgres exited unexpectedly with code {d}", .{code});
                    return error.PostgresExitedUnexpectedly;
                },
                .signal => |sig| {
                    std.log.err("Postgres crashed with signal {d}", .{sig});
                    return error.PostgresCrashed;
                },
                else => return error.PostgresAbnormalTermination,
            }
        }
    }

    pub fn kill(self: *@This(), sig: posix.SIG) KillError!void {
        if (self.child == null) return KillError.ProcessNotRunning;
        if (self.child.?.id == null) return KillError.ProcessNotRunning;

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            if (self.status == .Running)  {
                posix.kill(self.child.?.id.?, sig) catch |err| return switch (err) {
                    posix.KillError.PermissionDenied => KillError.PermissionDenied,
                    posix.KillError.ProcessNotFound => KillError.ProcessNotFound,
                    else => KillError.UnexpectedError,
                };
            }
        }

        if (self.monitor_future) |*fut| {
            fut.await(self.io);
            self.monitor_future = null;
        }

        if (self.stderr_future) |*fut| {
            fut.await(self.io);
            self.stderr_future = null;
        }

        self.child = null;
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

    const cwd = Dir.cwd();
    var data_file = try cwd.openFile(io, phantom.data_path, .{});
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
    defer phantom.deinit();

    try phantom.spawn();
}

test "phantom: spawn and kill" {
    const allocator = testing.allocator;
    const io = testing.io;

    const tmp_dir = testing.tmpDir(.{});

    const dest_path = try fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer allocator.free(dest_path);

    var phantom = try Phantom.init(allocator, io, "./test/template.db", dest_path);
    defer phantom.deinit();

    try phantom.spawn();

    const socket_path = try Dir.cwd().realPathFileAlloc(io, phantom.socket_path, allocator);
    defer allocator.free(socket_path);

    try createTable(allocator, io, socket_path);

    for (0..99) |_| {
        try phantom.kill(.TERM);
        try phantom.spawn();

        try insertRow(allocator, io, socket_path);
    }

    const count = try selectCount(allocator, io, socket_path);
    defer allocator.free(count);

    try testing.expectEqualSlices(u8, "99\n", count);
}

test "phantom: spawn multiple processes" {
    const allocator = testing.allocator;
    const io = testing.io;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dest_path = try fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp_dir.sub_path});
    defer allocator.free(dest_path);

    var phantom = try Phantom.init(allocator, io, "./test/template.db", dest_path);
    defer phantom.deinit();

    try phantom.spawn();

    const err = phantom.spawn();
    try testing.expectError(SpawnError.ProcessAlreadyExist, err);
}

fn createTable(allocator: Allocator, io: Io, socket: []const u8) !void {
    var pg_argv = [_][]const u8{
        "psql",
        "-h", socket,
        "-U", "postgres",
        "-q", "-t", "-A",
        "-c", "CREATE TABLE users(id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY, name VARCHAR(255) NOT NULL);",
    };
    const pg_result = try std.process.run(allocator, io, .{ 
        .argv = &pg_argv,
    });
    defer {
        allocator.free(pg_result.stdout);
        allocator.free(pg_result.stderr);
    }

    if (pg_result.term != .exited or pg_result.term.exited != 0 or pg_result.stderr.len > 0) {
        std.debug.print("Error: PSQL create failed: {s}\n", .{pg_result.stderr});
        return error.PsqlExecutionFailed;
    }
}

fn insertRow(allocator: Allocator, io: Io, socket: []const u8) !void {
    var pg_argv = [_][]const u8{
        "psql",
        "-h", socket,
        "-U", "postgres",
        "-q", "-t", "-A",
        "-c", "INSERT INTO users (name) VALUES ('kevin');",
    };
    const pg_result = try std.process.run(allocator, io, .{ 
        .argv = &pg_argv,
    });
    defer {
        allocator.free(pg_result.stdout);
        allocator.free(pg_result.stderr);
    }

    if (pg_result.term != .exited or pg_result.term.exited != 0 or pg_result.stderr.len > 0) {
        std.debug.print("Error: PSQL create failed: {s}\n", .{pg_result.stderr});
        return error.PsqlExecutionFailed;
    }
}

fn selectCount(allocator: Allocator, io: Io, socket: []const u8) ![]u8 {
    var pg_argv = [_][]const u8{ 
        "psql",
        "-h", socket,
        "-U", "postgres",
        "-q", "-t", "-A", // Formatting
        "-c", "SELECT COUNT(id) FROM users;",
    };
    const pg_result = try std.process.run(allocator, io, .{ 
        .argv = &pg_argv,
    });
    defer {
        allocator.free(pg_result.stdout);
        allocator.free(pg_result.stderr);
    }

    if (pg_result.term != .exited or pg_result.term.exited != 0 or pg_result.stderr.len > 0) {
        std.debug.print("Error: unable to select pg data: {s}\n", .{pg_result.stderr});
        return error.PgSelectError;
    }

    return try allocator.dupe(u8, pg_result.stdout);
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
