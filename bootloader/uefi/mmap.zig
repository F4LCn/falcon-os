const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;
const MemHelper = @import("mem_helper.zig");

const log = std.log.scoped(.mmap);

pub fn getMemMap(bootinfo: *BootInfo) BootloaderError!usize {
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

    log.debug("descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), descriptor_size });

    const mmap_entries: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    var mmap_idx: u64 = 0;
    var last_mmap_idx: ?u64 = null;

    var descriptor: *uefi.tables.MemoryDescriptor = undefined;
    var idx: usize = 0;
    const descriptors_count = mmap_size / descriptor_size;
    while (idx < descriptors_count) : (idx += 1) {
        log.debug("bootinfo.size = {d}", .{bootinfo.size});
        if (bootinfo.size > Constants.ARCH_PAGE_SIZE - @sizeOf(BootInfo.MmapEntry)) {
            log.err("Memory map is too big", .{});
            return BootloaderError.MemoryMapTooBig;
        }
        descriptor = @ptrFromInt(idx * descriptor_size + @intFromPtr(mmap));
        const descriptor_type = MemHelper.MemoryType.fromUefi(descriptor.type);
        log.debug("- Type={s}; {X} -> {X} (size: {X} pages); attr={X}", .{ @tagName(descriptor_type), descriptor.physical_start, descriptor.physical_start + Constants.ARCH_PAGE_SIZE * descriptor.number_of_pages, descriptor.number_of_pages, @as(u64, @bitCast(descriptor.attribute)) });

        const entry_type: BootInfo.MmapEntry.Type = switch (descriptor_type) {
            .LoaderCode, .LoaderData, .BootServicesCode, .BootServicesData, .ConventionalMemory => .FREE,
            .ACPIReclaimMemory, .ACPIMemoryNVS => .ACPI,
            .PAGING => .PAGING,
            .RECLAIMABLE => .RECLAIMABLE,
            .BOOTINFO => .BOOTINFO,
            .KERNEL_MODULE => .KERNEL_MODULE,
            .FRAMEBUFFER => .FRAMEBUFFER,
            else => .USED,
        };

        const mmap_entry = &mmap_entries[mmap_idx];
        mmap_entry.* = BootInfo.MmapEntry.create(descriptor.physical_start, descriptor.number_of_pages * Constants.ARCH_PAGE_SIZE, entry_type);

        if (last_mmap_idx) |last_idx| {
            const last_mmap_entry = &mmap_entries[last_idx];
            if (mmap_entry.getType() == last_mmap_entry.getType() and mmap_entry.getPtr() == last_mmap_entry.getEnd()) {
                log.debug("Extending last mmap entry (contiguous): {any}", .{mmap_entry});
                last_mmap_entry.size += mmap_entry.size;
                mmap_entry.ptr = 0;
                mmap_entry.size = 0;
                continue;
            }
            log.debug("Creating a new mmap entry (not contiguous): {any}", .{mmap_entry});
            last_mmap_idx = mmap_idx;
        } else {
            log.debug("Creating a new mmap entry (first iteration): {any}", .{mmap_entry});
            last_mmap_idx = mmap_idx;
        }

        bootinfo.size += @sizeOf(BootInfo.MmapEntry);
        mmap_idx += 1;
    }
    log.info("Created {d} mmap entries, bootinfo size: {d}", .{mmap_idx, bootinfo.size});
    return mapKey;
}
