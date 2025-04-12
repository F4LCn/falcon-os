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

        pub fn format(
            self: *const @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}", .{ self, self.getPtr(), self.getEnd(), self.getSize(), @tagName(self.getType()) });
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
    unused1: [31]u8,
    acpi_ptr: u64,
    unused2: [24]u8,
    mmap: MmapEntry,
};
