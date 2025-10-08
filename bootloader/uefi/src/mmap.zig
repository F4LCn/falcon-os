const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;
const MemHelper = @import("mem_helper.zig");

const log = std.log.scoped(.mmap);

pub fn buildMmap(bootinfo: *BootInfo) BootloaderError!u64 {
    var status: uefi.Status = undefined;
    const boot_services = Globals.boot_services;

    var mmap_size: usize = 0;
    var mmap: ?[*]uefi.tables.MemoryDescriptor = null;
    var mapKey: uefi.tables.MemoryMapKey = undefined;
    var descriptor_size: usize = undefined;
    var descriptor_version: u32 = undefined;
    status = boot_services._getMemoryMap(&mmap_size, @ptrCast(mmap), &mapKey, &descriptor_size, &descriptor_version);
    switch (status) {
        .buffer_too_small => log.debug("Need {d} bytes for memory map buffer", .{mmap_size}),
        else => {
            log.err("Expected BufferTooSmall but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    mmap_size += 2 * descriptor_size;
    status = boot_services._allocatePool(MemHelper.MemoryType.RECLAIMABLE.toUefi(), mmap_size, @ptrCast(&mmap));
    switch (status) {
        .success => log.debug("Allocated {d} bytes for memory map at {*}", .{ mmap_size, mmap }),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    status = boot_services._getMemoryMap(&mmap_size, @ptrCast(mmap), &mapKey, &descriptor_size, &descriptor_version);
    switch (status) {
        .success => log.debug("Got memory map", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    log.debug("descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), descriptor_size });

    const mmap_entries: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    var mem_limit: u64 = 0;
    var mmap_idx: u64 = 0;
    var last_mmap_idx: ?u64 = null;

    var descriptor: *uefi.tables.MemoryDescriptor = undefined;
    var idx: usize = 0;
    const descriptors_count = @divExact(mmap_size, descriptor_size);
    while (idx < descriptors_count) : (idx += 1) {
        log.debug("bootinfo.size = {d}", .{bootinfo.size});
        if (bootinfo.size > Constants.arch_page_size - @sizeOf(BootInfo.MmapEntry)) {
            log.err("Memory map is too big", .{});
            return BootloaderError.MemoryMapTooBig;
        }
        descriptor = @ptrFromInt(idx * descriptor_size + @intFromPtr(mmap));
        if (@as(u64, @bitCast(descriptor.attribute)) == 0) continue;
        const descriptor_type = MemHelper.MemoryType.fromUefi(descriptor.type);
        log.debug("- Type={s}; {X} -> {X} (size: {X} pages); attr={X}", .{ @tagName(descriptor_type), descriptor.physical_start, descriptor.physical_start + Constants.arch_page_size * descriptor.number_of_pages, descriptor.number_of_pages, @as(u64, @bitCast(descriptor.attribute)) });

        const entry_type: BootInfo.MmapEntry.Type = switch (descriptor_type) {
            .LoaderCode, .loader_data, .BootServicesCode, .BootServicesData, .ConventionalMemory => .FREE,
            .ACPIReclaimMemory, .ACPIMemoryNVS => .ACPI,
            .PAGING => .PAGING,
            .RECLAIMABLE => .RECLAIMABLE,
            .BOOTINFO => .BOOTINFO,
            .KERNEL_MODULE => .KERNEL_MODULE,
            .FRAMEBUFFER => .FRAMEBUFFER,
            .TRAMPOLINE => .TRAMPOLINE,
            else => .USED,
        };

        const mmap_entry = &mmap_entries[mmap_idx];
        mmap_entry.* = BootInfo.MmapEntry.create(descriptor.physical_start, descriptor.number_of_pages * Constants.arch_page_size, entry_type);
        if (mem_limit < mmap_entry.getEnd()) {
            mem_limit = mmap_entry.getEnd();
        }

        if (last_mmap_idx) |last_idx| {
            const last_mmap_entry = &mmap_entries[last_idx];
            if (mmap_entry.getType() == last_mmap_entry.getType() and mmap_entry.getPtr() == last_mmap_entry.getEnd()) {
                log.debug("Extending last mmap entry (contiguous): {any}", .{mmap_entry});
                last_mmap_entry.len += mmap_entry.len;
                mmap_entry.ptr = 0;
                mmap_entry.len = 0;
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
    log.info("Created {d} mmap entries, bootinfo size: {d}", .{ mmap_idx, bootinfo.size });
    return mem_limit;
}

pub fn getMmapKey() BootloaderError!uefi.tables.MemoryMapKey {
    var mmap_size: usize = 0;
    const mmap: ?[*]uefi.tables.MemoryDescriptor = null;
    var mapKey: uefi.tables.MemoryMapKey = undefined;
    var descriptor_size: usize = undefined;
    var descriptor_version: u32 = undefined;
    const boot_services = Globals.boot_services;
    const status = boot_services._getMemoryMap(&mmap_size, @ptrCast(mmap), &mapKey, &descriptor_size, &descriptor_version);
    switch (status) {
        .buffer_too_small => log.debug("Need {d} bytes for memory map buffer", .{mmap_size}),
        else => {
            log.err("Expected BufferTooSmall but got {s} instead", .{@tagName(status)});
            return BootloaderError.MemoryMapError;
        },
    }

    return mapKey;
}
