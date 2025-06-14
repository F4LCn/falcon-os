pub const BootInfo = packed struct {
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

    pub const MmapEntry = packed struct {
        pub const Type = enum(u12) {
            USED,
            FREE,
            ACPI,
            RECLAIMABLE,
            BOOTINFO,
            FRAMEBUFFER,
            KERNEL_MODULE,
            PAGING,
        };

        ptr: u64,
        size: u64,

        pub fn create(ptr: u64, size: u64, typ: Type) MmapEntry {
            const ptr_with_typ = ptr + @intFromEnum(typ);
            return .{
                .ptr = ptr_with_typ,
                .size = size,
            };
        }

        pub fn getPtr(self: MmapEntry) u64 {
            const type_mask: u64 = 0xfff;
            const ptr_mask = ~type_mask;
            return self.ptr & ptr_mask;
        }

        pub fn getSize(self: MmapEntry) u64 {
            return self.size;
        }

        pub fn getEnd(self: MmapEntry) u64 {
            return self.getPtr() + self.getSize();
        }

        pub fn getType(self: MmapEntry) Type {
            const type_mask: u64 = 0xfff;
            return @enumFromInt(self.ptr & type_mask);
        }
    };

    magic: u32 = 0x464C434E,
    size: u32 = 96,
    bootloader_type: BootloaderType,
    unused0: u24 = undefined,
    fb_ptr: u64 = 0,
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    fb_scanline_bytes: u32 = 0,
    fb_pixelformat: PixelFormat = @enumFromInt(0),
    unused1: u248 = undefined,
    acpi_ptr: u64 = 0,
    unused2: u192 = undefined,
    mmap: MmapEntry = undefined,
};
