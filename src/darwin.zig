const builtin = @import("builtin");

const std = @import("std");
const fd_t = std.c.fd_t;
const Io = std.Io;
const assert = std.debug.assert;

comptime {
    assert(builtin.os.tag.isDarwin()); // Prevent access of std.c symbols on wrong OS.
}

// consts from Darwin <sys/attr.h> and <sys/stat.h>
pub const ATTR_BIT_MAP_COUNT: u16 = 5;
pub const FSOPT_ATTR_CMN_EXTENDED: c_ulong = 0x00000020;

pub const ATTR_CMNEXT_PRIVATESIZE: u32 = 0x00000008;
pub const ATTR_CMNEXT_CLONEID: u32 = 0x00000100;
pub const ATTR_CMNEXT_EXT_FLAGS: u32 = 0x00000200;
pub const ATTR_CMNEXT_CLONE_REFCNT: u32 = 0x00001000;

pub const EF_MAY_SHARE_BLOCKS: u64 = 0x00000001;
pub const EF_SHARES_ALL_BLOCKS: u64 = 0x00000040;

pub const AttrList = extern struct {
    bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};

pub const CloneAttrBuf = extern struct {
    length: u32 align(4),
    private_size: i64 align(4),
    clone_id: u64 align(4),
    ext_flags: u64 align(4),
    clone_refcnt: u32 align(4),
};

comptime {
    assert(@sizeOf(AttrList) == 24);
    assert(@sizeOf(CloneAttrBuf) == 32);
}

pub extern "c" fn fclonefileat(src: fd_t, dest_dir: fd_t, dst: [*:0]const u8, flags: c_int) c_int;

pub extern "c" fn fgetattrlist(
    fd: fd_t,
    attrList: *const AttrList,
    attrBuf: *anyopaque,
    attrBufSize: usize,
    options: c_ulong,
) c_int;
