const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const ConnectionError = error{
ProcessNotStartedError,
};

const Status = enum(u8) {
    init,
    running,
    stopped
};

const Config = struct {
    dir: []const u8,
    temp_dir: []const u8,
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

    pub fn init(allocator: Allocator, io: Io, config: Config) @This() {
        const id = Io.Clock.real.now(io).toNanoseconds();

        const connection = Connection{
            .allocator = allocator,
            .io = io,
            .id = id,
            .data_path = std.fmt.allocPrint(allocator, "{s}/data/data_{d}", .{ config.temp_dir, id }),
            .socket_path = std.fmt.allocPrint(allocator, "{s}/socket/sock_{d}", .{ config.temp_dir, id }),
            .status = .init,
        };

        switch (config.os_tag) {
            .macos => std.fmt.allocPrint(connection.allocator, "cp -a -c {s} {s}", .{ config.dir, connection.data_path }),
            .linux => std.fmt.allocPrint(connection.allocator, "cp --reflink=always {s} {s}", .{ config.dir, connection.data_path }),
        }

        return connection;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.data_path);
        self.allocator.free(self.socket_path);
    }

    pub fn boot(self: *@This()) ![]const u8 {
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
        self.status = .running;

        return self.socket_path;
    }

    pub fn kill(self: *@This(), sig: std.posix.SIG) !std.process.Child.Term {
        if (self.process.id) |pid| {
            try std.posix.kill(pid, sig);
        } else {
            return ConnectionError.ProcessNotStartedError;
        }

        self.status = .stopped;

        return try self.process.wait(self.io);
    }
};
