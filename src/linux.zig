const std = @import("std");
const assert = std.debug.assert;

// consts from Linux <linux/fs.h>
pub const FICLONE = 0x40049409;

pub const FS_IOC_FIEMAP = 0xC020660B;

const FIEMAP_FLAG_SYNC = 0x00000001;
pub const FIEMAP_EXTENT_SHARED = 0x00002000;

const FiemapExtent = extern struct {
    fe_logical: u64 = 0,
    fe_physical: u64 = 0,
    fe_length: u64 = 0,
    fe_reserved64: [2]u64 = .{ 0, 0 },
    fe_flags: u32 = 0,
    fe_reserved: [3]u32 = .{ 0, 0, 0 },
};

pub const FiemapRequest = extern struct {
    fm_start: u64 = 0,
    fm_length: u64 = std.math.maxInt(u64),
    fm_flags: u32 = FIEMAP_FLAG_SYNC,
    fm_mapped_extents: u32 = 0,
    fm_extent_count: u32 = 1,
    fm_reserved: u32 = 0,
    fm_extents: [1]FiemapExtent = .{.{}},
};

comptime {
    assert(@sizeOf(FiemapExtent) == 56);
    assert(@sizeOf(FiemapRequest) == 32 + 56);
}
