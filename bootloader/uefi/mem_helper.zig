const std = @import("std");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const Globals = @import("globals.zig");

const log = std.log.scoped(.MemHelper);

pub fn kb(val: comptime_int) comptime_int {
    return val * 1024;
}

pub fn mb(val: comptime_int) comptime_int {
    return kb(val) * 1024;
}

pub fn gb(val: comptime_int) comptime_int {
    return mb(val) * 1024;
}

pub const MemoryType = enum(u32) {
    ReservedMemoryType,
    LoaderCode,
    loader_data,
    BootServicesCode,
    BootServicesData,
    RuntimeServicesCode,
    RuntimeServicesData,
    ConventionalMemory,
    UnusableMemory,
    ACPIReclaimMemory,
    ACPIMemoryNVS,
    MemoryMappedIO,
    MemoryMappedIOPortSpace,
    PalCode,
    PersistentMemory,
    MaxMemoryType,
    RECLAIMABLE = 0x80000000,
    BOOTINFO,
    FRAMEBUFFER,
    KERNEL_MODULE,
    PAGING,

    pub fn toUefi(self: MemoryType) std.os.uefi.tables.MemoryType {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn fromUefi(value: std.os.uefi.tables.MemoryType) MemoryType {
        return @enumFromInt(@intFromEnum(value));
    }
};

pub fn allocatePages(num_pages: u64, typ: MemoryType) BootloaderError![*]align(Constants.ARCH_PAGE_SIZE) u8 {
    var page_ptr: [*]align(Constants.ARCH_PAGE_SIZE) u8 = undefined;
    const status = Globals.boot_services.allocatePages(.allocate_any_pages, typ.toUefi(), num_pages, &page_ptr);
    switch (status) {
        .success => log.debug("Allocated {d} pages at 0x{X}", .{ num_pages, @intFromPtr(page_ptr) }),
        else => return BootloaderError.AddressSpaceAllocatePages,
    }
    @memset(page_ptr[0 .. num_pages * Constants.ARCH_PAGE_SIZE], 0);
    return page_ptr;
}

test "MemoryType to UEFI" {
    for (std.enums.values(MemoryType)) |value| {
        const uefi_value: std.os.uefi.tables.MemoryType = value.toUefi();
        if (@intFromEnum(value) <= @intFromEnum(std.os.uefi.tables.MemoryType.MaxMemoryType)) {
            try std.testing.expectEqualStrings(@tagName(uefi_value), @tagName(value));
        } else {
            try std.testing.expectEqual(@intFromEnum(uefi_value), @intFromEnum(value));
        }
    }
}

test "UEFI to MemoryType" {
    var uefi_value: std.os.uefi.tables.MemoryType = .loader_data;
    try std.testing.expectEqual(MemoryType.loader_data, MemoryType.fromUefi(uefi_value));
    uefi_value = @enumFromInt(0x80000001);
    try std.testing.expectEqual(MemoryType.BOOTINFO, MemoryType.fromUefi(uefi_value));
}
