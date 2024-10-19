pub const BootloaderType = enum(u8) {
    BIOS = 0,
    UEFI = 1,
};

pub const PixelFormat = enum(u8) {
    ARGB = 0,
    RGBA = 1,
    ABGR = 2,
    BGRA = 3,
};

pub const MmapEntry = extern struct {
    ptr: u64,
    size: u64,
};

magic: [4]u8 = [_]u8{ 'F', 'L', 'C', 'N' },
size: u32 = 96,
bootloader_type: BootloaderType,
unused0: [3]u8 = undefined,
fb_ptr: ?u64 = null,
fb_width: ?u32 = null,
fb_height: ?u32 = null,
fb_scanline_bytes: ?u32 = null,
fb_pixelformat: ?PixelFormat = null,
unused1: [31]u8 = undefined,
acpi_ptr: ?u64 = null,
unused2: [24]u8 = undefined,
mmap: [1]MmapEntry = undefined,
