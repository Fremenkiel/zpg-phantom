const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const assert = std.debug.assert;

pub fn main(init: std.process.Init) !void {
    _ = init;
    const line = "2026-11-13 06:26:57.867 EET [35362] FATAL:  empty password returned by client";

    const msg = try parseLoggedMessage(line);

    assert(.err == msg.severity);
    assert(mem.eql(u8, "2026-11-13 06:26:57.867", msg.timestamp));
    assert(mem.eql(u8, "EET", msg.timezone));
    assert(mem.eql(u8, "35362", msg.pid));
    assert(mem.eql(u8, "empty password returned by client", msg.message));
}

const LogMessage = struct {
    timestamp: []const u8,
    timezone: []const u8,
    pid: []const u8,
    severity: std.log.Level,
    message: []const u8
};

fn parseLoggedMessage(line: []const u8) !LogMessage {
    assert(line.len > 0);

    var reader = Io.Reader.fixed(line);
    const timestamp = try reader.take(23);
    std.log.info("timestamp: {s}", .{ timestamp });

    // discard space
    _ = try reader.take(1);

    const timezone = try reader.takeDelimiterExclusive(' ');
    std.log.info("timezone: {s}", .{ timestamp });

    // discard space and left bracket
    _ = try reader.take(2);

    const pid = try reader.takeDelimiterExclusive(']');
    std.log.info("pid: {s}", .{ timezone });

    // discard right bracket and space
    _ = try reader.take(2);

    const severity = try reader.takeDelimiterExclusive(':');
    std.log.info("severity: {s}", .{ severity });

    assert(severity.len > 0);

    // discard colon 
    _ = try reader.take(1);

    while (true) {
        const char = try reader.peekByte();
        switch (char) {
            '\t', ' ' => {},
            else => break,
        }

        _ = try reader.takeByte();
    }

    const remaining = reader.end - reader.seek;
    std.log.info("remaining: {d}", .{ remaining });

    assert(remaining > 0);

    const msg = try reader.take(remaining);
    std.log.info("msg: {s}", .{ msg });

    return LogMessage{
        .timestamp = timestamp,
        .timezone = timezone,
        .pid = pid,
        .severity = switch (severity[0]) {
            'D' => .debug,
            'I', 'L' => .info,
            'W', 'N' => .warn,
            'E', 'F' => .err,
            'P' => @panic(msg),
            else => return error.InvalidSeverity,
        },
        .message = msg,
    };
}
