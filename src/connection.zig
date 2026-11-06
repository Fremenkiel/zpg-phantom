const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const ConnectionError = error{
ProcessNotStartedError,
UnexpectedError,
} || Allocator.Error;

pub const SpawnError = error{
UnexpectedError,
};

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

const Config = struct {
    template_file_path: []const u8,
    tmp_dir_path: []const u8,
    os_tag: std.Target.Os.Tag,
};

pub const Connection = struct {
    allocator: Allocator,
    io: Io,

    id: i96,

    data_path: []const u8,
    socket_path: []const u8,

    status: Status,

    process: *std.process.Child,

    pub fn init(allocator: Allocator, io: Io, config: Config) ConnectionError!@This() {
        const id = Io.Clock.real.now(io).toNanoseconds();

        const connection = Connection{
            .allocator = allocator,
            .io = io,
            .id = id,
            .data_path = std.fmt.allocPrint(allocator, "{s}/data/data_{d}", .{ config.temp_dir, id }),
            .socket_path = std.fmt.allocPrint(allocator, "{s}/socket/sock_{d}", .{ config.temp_dir, id }),
            .status = .INITIALIZED,
        };

        switch (config.os_tag) {
            .macos => std.fmt.allocPrint(connection.allocator, "cp -a -c {s} {s}", .{ config.template_file, connection.data_path }) catch { return ConnectionError.OutOfMemory; },
            .linux => std.fmt.allocPrint(connection.allocator, "cp --reflink=always {s} {s}", .{ config.template_file, connection.data_path }) catch { return ConnectionError.OutOfMemory; },
        }

        return connection;
    }

    pub fn deinit(self: *@This()) void {
        if (self.status == .RUNNING) {
            _ = self.kill(.KILL) catch |err| {
                // Assuming process is already killed
                if (err == KillError.ProcessNotFound) {
                    self.status = .STOPPED;
                    return;
                }

                const msg = std.fmt.allocPrint(self.allocator, "unable to kill process #{d}", .{ self.process.id.? }) catch {
                    @panic("unable to kill process");
                };

                @panic(msg);
            };
        }

        self.allocator.free(self.data_path);
        self.allocator.free(self.socket_path);
    }

    pub fn boot(self: *@This()) SpawnError![]const u8 {
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

        var process = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        self.process = &process;
        self.status = .RUNNING;

        return self.socket_path;
    }

    pub fn kill(self: *@This(), sig: std.posix.SIG) KillError!std.process.Child.Term {
        if (self.process.id) |pid| {
            std.posix.kill(pid, sig) catch |err| return switch (err) {
                std.posix.KillError.PermissionDenied => KillError.PermissionDenied,
                std.posix.KillError.ProcessNotFound => KillError.ProcessNotFound,
                else => KillError.UnexpectedError,
            };
        } else {
            return KillError.ProcessNotRunning;
        }

        const term = self.process.wait(self.io) catch |err| {
            self.status = .FAILED;

            return switch (err) {
                std.process.Child.WaitError.AccessDenied => KillError.AccessDenied,
                std.process.Child.WaitError.Canceled => KillError.Canceled,
                else => KillError.UnexpectedError,
            };
        };

        self.status = .STOPPED;

        return term;
    }

    pub fn getPid(self: *@This()) ?std.process.Child.Id {
        return self.process.id;
    }
};
