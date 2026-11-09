const builtin = @import("builtin");
const native_os = builtin.os.tag;
const is_darwin = native_os.isDarwin();
const is_linux = native_os == .linux;

const std = @import("std");
const c = std.c;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Atomic = File.Atomic;
const posix = std.posix;
const Threaded = Io.Threaded;
const assert = std.debug.assert;

const linux = @import("linux.zig");
const darwin = @import("darwin.zig");

pub const CopyOnWriteError = error{
SourceFileUnavaliable,
PermissionNotSet,
Unimplemented
} || Io.UnexpectedError || Dir.CreateFileAtomicError || Dir.PathNameError || Atomic.ReplaceError || Atomic.LinkError;

// todo: error handling (Kevin)
pub fn copyOnWrite(
source_dir: Dir,
source_path: []const u8,
dest_dir: Dir,
dest_path: []const u8,
io: Io,
options: Dir.CopyFileOptions,
) CopyOnWriteError!void {
    const file = source_dir.openFile(io, source_path, .{ .mode = .read_only }) catch return CopyOnWriteError.SourceFileUnavaliable;
    defer file.close(io);

    if (is_linux) {
        const permissions = options.permissions orelse blk: {
            const st = file.stat(io) catch return CopyOnWriteError.PermissionNotSet;
            break :blk st.permissions;
        };

        var atomic_file = try dest_dir.createFileAtomic(io, dest_path, .{
            .permissions = permissions,
            .make_path = options.make_path,
            .replace = options.replace,
        });
        defer atomic_file.deinit(io);

        const src_fd: usize = @intCast(file.handle);
        switch (posix.errno(posix.system.ioctl(atomic_file.file.handle, linux.FICLONE, src_fd))) {
            .SUCCESS => {
                switch (options.replace) {
                    true => try atomic_file.replace(io),
                    false => try atomic_file.link(io),
                }

                return;
            },
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    if (is_darwin) {
        var dest_path_buffer: [posix.PATH_MAX]u8 = undefined;
        const dest_path_posix = try Threaded.pathToPosix(dest_path, &dest_path_buffer);

        const rc = darwin.fclonefileat(file.handle, dest_dir.handle, dest_path_posix, 0);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                return;
            },
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    return CopyOnWriteError.Unimplemented;
}

const FileStat = struct {
    size: u64,
    physical: u64,
    shared: bool,
};

const FileStatError = error{
SourceFileUnavaliable,
InvalidFiemap,
Unimplemented
} || Io.UnexpectedError;

fn fileStat(
dir: Dir,
path: []const u8,
io: Io,
) FileStatError!FileStat {
    const file = dir.openFile(io, path, .{ .mode = .read_only, }) catch return FileStatError.SourceFileUnavaliable;
    defer file.close(io);

    if (is_linux) {
        var request: linux.FiemapRequest = .{};
        switch (posix.errno(posix.system.ioctl(file.handle, linux.FS_IOC_FIEMAP, @intFromPtr(&request)))) {
            .SUCCESS => {
                if (request.fm_mapped_extents == 0) {
                    return error.InvalidFiemap;
                }

                const extent = request.fm_extents[0];

                return .{
                    .size = extent.fe_length,
                    .physical = extent.fe_physical,
                    .shared = (extent.fe_flags & linux.FIEMAP_EXTENT_SHARED) != 0,
                };
            },
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    if (is_darwin) {
        var attr_list = darwin.AttrList{
            .forkattr = darwin.ATTR_CMNEXT_PRIVATESIZE |
            darwin.ATTR_CMNEXT_CLONEID |
            darwin.ATTR_CMNEXT_EXT_FLAGS |
            darwin.ATTR_CMNEXT_CLONE_REFCNT,
        };

        var buf: darwin.CloneAttrBuf = undefined;

        switch (posix.errno(darwin.fgetattrlist(file.handle, &attr_list, &buf, @sizeOf(darwin.CloneAttrBuf), darwin.FSOPT_ATTR_CMN_EXTENDED))) {
            .SUCCESS => {
                return .{
                    .size = @as(u64, @bitCast(buf.private_size)),
                    .physical = buf.clone_id,
                    .shared = (buf.ext_flags & darwin.EF_SHARES_ALL_BLOCKS) != 0,
                };
            },
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }

    return FileStatError.Unimplemented;
}

const testing = std.testing;

test "reflink: copy on write" {
    const io = testing.io;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = tmp_dir.dir;
    const src_path = "src.bin";
    const dest_path = "cow.bin";

{
        const f = try dir.createFile(io, src_path, .{ .truncate = true });
        defer f.close(io);
        const data: [64 * 1024]u8 = @splat('A');

        var buffer: [1024]u8 = undefined;
        var file_writer = f.writer(io, &buffer);

        var w = &file_writer.interface;

        try w.writeAll(&data);

        try file_writer.flush();

        try f.sync(io);
    }
    defer dir.deleteFile(io, src_path) catch {};

    try copyOnWrite(dir, src_path, dir, dest_path, io, .{
        .replace = false
    });
    defer dir.deleteFile(io, dest_path) catch {};

    const src_info = try fileStat(dir, src_path, io);
    const cow_info = try fileStat(dir, dest_path, io);

    if (is_linux) {
        try testing.expectEqual(@as(u64, 64 * 1024), cow_info.size);
        try testing.expect(src_info.physical != 0);
    }

    if (is_darwin) {
        try testing.expectEqual(src_info.physical, cow_info.physical);
        try testing.expectEqual(cow_info.size, 0);
    }

    try testing.expectEqual(cow_info.shared, true);
}
