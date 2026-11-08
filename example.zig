const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const phantom = @import("phantom");
const Phantom = phantom.Phantom;

pub fn run(allocator: Allocator, io: Io) !void {
    var database = try Phantom.init(allocator, io, "./test/template.db", "/tmp");
    defer database.deinit();

    {
        try database.spawn();

        var pg_argv = [_][]const u8{
            "psql",
            "-h", database.socket_path,
            "-U", "postgres",
            "-q", "-t", "-A", // Formatting
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

    try database.kill(.TERM);

    {
        try database.spawn();

        var pg_argv = [_][]const u8{
            "psql",
            "-h", database.socket_path,
            "-U", "postgres",
            "-q", "-t", "-A", // Formatting
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
}

const testing = std.testing;

test "exapmle: run" {
    const allocator = testing.allocator;
    const io = testing.io;

    try run(allocator, io);
}
