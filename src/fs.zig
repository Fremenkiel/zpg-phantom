const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const fmt = std.fmt;

pub const TmpDir = struct {
    dir: Dir,
    parent_dir: Dir,
    sub_path: [sub_path_len]u8,

    const random_bytes_count = 12;
    const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

    pub fn cleanup(self: *TmpDir, io: Io) void {
        self.dir.close(io);
        self.parent_dir.deleteTree(io, &self.sub_path) catch {};
        self.parent_dir.close(io);
        self.* = undefined;
    }
};

pub fn tmpDir(io: Io, parent_path: []const u8) !TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    io.random(&random_bytes);
    var sub_path: [TmpDir.sub_path_len]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

    const cwd = Dir.cwd();
    const parent_dir = try cwd.openDir(io, parent_path, .{});

    const dir = try parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = .{} });

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}

const testing = std.testing;

test "fs: create file" {
    const allocator = testing.allocator;
    const io = testing.io;
    var tmp_dir = try tmpDir(io, "./test");
    defer tmp_dir.cleanup(io);

    const dir_path = try fmt.allocPrint(allocator, "./test/{s}", .{ tmp_dir.sub_path });
    defer allocator.free(dir_path);

    const cwd = Dir.cwd();
    const dir = try cwd.openDir(io, dir_path, .{});
    defer dir.close(io);
}
