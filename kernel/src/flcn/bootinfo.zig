const std = @import("std");
pub const BootInfo = extern struct {
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
            TRAMPOLINE,
        };

        ptr: u64,
        len: u64,

        pub fn create(ptr: u64, size: u64, typ: Type) MmapEntry {
            const ptr_with_typ = ptr + @intFromEnum(typ);
            return .{
                .ptr = ptr_with_typ,
                .len = size,
            };
        }

        pub fn getPtr(self: MmapEntry) u64 {
            const type_mask: u64 = 0xfff;
            const ptr_mask = ~type_mask;
            return self.ptr & ptr_mask;
        }

        pub fn getLen(self: MmapEntry) u64 {
            return self.len;
        }

        pub fn getEnd(self: MmapEntry) u64 {
            return self.getPtr() + self.getLen();
        }

        pub fn getType(self: MmapEntry) Type {
            const type_mask: u64 = 0xfff;
            return @enumFromInt(self.ptr & type_mask);
        }

        pub fn format(
            self: *const @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("{*}[0x{X} -> 0x{X} (len={X}) {s}", .{ self, self.getPtr(), self.getEnd(), self.getLen(), @tagName(self.getType()) });
        }
    };

    magic: [4]u8,
    size: u32,
    bootloader_type: BootloaderType,
    unused0: [3]u8,
    fb_ptr: u64 align(1),
    fb_width: u32,
    fb_height: u32,
    fb_scanline_bytes: u32,
    fb_pixelformat: PixelFormat,
    unused1: u8,
    debug_info_ptr: u64 align(1),
    unused2: [22]u8,
    acpi_ptr: u64,
    unused3: [24]u8,
    mmap: MmapEntry,
};

comptime {
    if ((@bitSizeOf(BootInfo) - @bitSizeOf(BootInfo.MmapEntry)) != 8 * 96) {
        const details = std.fmt.comptimePrint("Expect {d} bytes but found {d}", .{ 96, @divExact(@bitSizeOf(BootInfo) - @bitSizeOf(BootInfo.MmapEntry), 8) });
        @compileError("BootInfo got too large. " ++ details);
    }
}
