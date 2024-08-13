const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;

const log = std.log.scoped(.mmap);

pub fn getMemMap() BootloaderError!void {
    var status: uefi.Status = undefined;
    const boot_services = Globals.boot_services;

    var mmap_size: usize = 0;
    var mmap: ?[*]uefi.tables.MemoryDescriptor = null;
    var mapKey: usize = undefined;
    var descriptor_size: usize = undefined;
    var desscriptor_version: u32 = undefined;
    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .BufferTooSmall => log.debug("Need {d} bytes for memory map buffer", .{mmap_size}),
        else => {
            log.err("Expected BufferTooSmall but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    mmap_size += 2 * descriptor_size;
    status = boot_services.allocatePool(.LoaderData, mmap_size, @ptrCast(&mmap));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for memory map at {*}", .{ mmap_size, mmap }),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .Success => log.debug("Got memory map", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    log.info("descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), descriptor_size });

    var descriptor: *uefi.tables.MemoryDescriptor = undefined;
    var idx: usize = 0;
    const descriptors_count = mmap_size / descriptor_size;
    while (idx < descriptors_count) : (idx += 1) {
        descriptor = @ptrFromInt(idx * descriptor_size + @intFromPtr(mmap));
        log.info("- Type={s}; {X} -> {X} (size: {X} pages); attr={X}", .{ @tagName(descriptor.type), descriptor.physical_start, descriptor.physical_start + 4096 * descriptor.number_of_pages, descriptor.number_of_pages, @as(u64, @bitCast(descriptor.attribute)) });
    }
}
