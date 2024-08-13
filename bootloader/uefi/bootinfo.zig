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

pub const BootInfo = extern struct {
    magic: [4]u8,
    size: u32,
    bootloader_type: BootloaderType,
    unused0: [3]u8 = undefined,
    fb_ptr: u64,
    fb_width: u32,
    fb_height: u32,
    fb_scanline_bytes: u32,
    fb_pixelformat: PixelFormat,
    unused1: [31]u8 = undefined,
    acpi_ptr: u64,
    unused2: [24]u8 = undefined,
    mmap: [@divFloor((4096 - 96), @sizeOf(MmapEntry))]MmapEntry = undefined,
};
