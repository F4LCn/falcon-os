const std = @import("std");
const options = @import("options");
const arch = @import("arch");
const flcn = @import("flcn");
const BootInfo = flcn.bootinfo.BootInfo;
const DoublyLinkedList = flcn.list.DoublyLinkedList;
const SpinLock = flcn.synchronization.SpinLock;
const mem_allocator = @import("flcn").allocator;

extern var bootinfo: BootInfo;
var mmap_entries: []BootInfo.MmapEntry = undefined;

const log = std.log.scoped(.pmem);
const Error = error{OutOfPhysMemory};

pub const PAddr = arch.memory.PAddr;
pub const PAddrSize = arch.memory.PAddrSize;
const PageAllocator = flcn.buddy.Buddy(.{ .min_size = arch.constants.default_page_size, .safety = false });
pub const PhysicalMemoryManager = flcn.pmm.PhysicalMemoryManager;
pub const PhysMemRange = flcn.pmm.PhysMemRange;
pub const PhysRangeType = flcn.pmm.PhysRangeType;

const PhysMemRangeListItem = flcn.pmm.PhysMemRangeListItem;
const PhysMemRangeAllocator = flcn.pmm.PhysMemRangeAllocator(PageAllocator);
const PhysMemRangeAllocatorList = flcn.pmm.PhysMemRangeAllocatorList(PageAllocator);

var mm: PhysicalMemoryManager = undefined;
var page_allocators: PhysMemRangeAllocatorList = .{};
var alloc: std.mem.Allocator = undefined;

pub fn init(a: std.mem.Allocator) !void {
    alloc = a;
    mm = .init();

    mm.lock.lock();
    defer mm.lock.unlock();

    log.debug("bootinfo ptr: {*}, size: {d}", .{ &bootinfo, bootinfo.size });
    const mmaps: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    // bootinfo size - bootinfo header size = mmap size (total) / sizeof(mmap) => mmap count
    const bootinfo_header_size = @intFromPtr(mmaps) - @intFromPtr(&bootinfo);
    log.debug("bootinfo header size: expecting 96B : got {d}B", .{bootinfo_header_size});
    const mmap_size = bootinfo.size - bootinfo_header_size;
    log.debug("mmap size is: {d}, size of an mmap entry {d}", .{ mmap_size, @sizeOf(BootInfo.MmapEntry) });
    const mmap_count = @divExact(mmap_size, @sizeOf(BootInfo.MmapEntry));
    log.debug("mmap count: {d}", .{mmap_count});
    mmap_entries = mmaps[0..mmap_count];

    reclaimFreeableMemory();
    try initRanges();

    mm.uncommitted_pages_count = mm.free_pages_count;
}

pub fn printRanges() void {
    var iter = mm.free_ranges.iter();
    log.debug("Free Physical memory ranges:", .{});
    while (iter.next()) |list_item| {
        log.debug("{f}", .{list_item});
    }

    iter = mm.reserved_ranges.iter();
    log.debug("Reserved Physical memory ranges:", .{});
    while (iter.next()) |list_item| {
        log.debug("{f}", .{list_item});
    }

    log.debug("Total system memory: {X}", .{mm.total_memory});
}

fn reclaimFreeableMemory() void {
    var idx: u64 = 0;
    var last_idx: ?u64 = null;
    while (idx < mmap_entries.len) : (idx += 1) {
        var keep_last = false;
        const entry = &mmap_entries[idx];
        if (entry.getType() == .RECLAIMABLE) {
            entry.* = BootInfo.MmapEntry.create(entry.getPtr(), entry.getLen(), .FREE);
        }

        if (last_idx) |li| {
            const last_entry = &mmap_entries[li];
            if (last_entry.getEnd() == entry.getPtr() and last_entry.getType() == entry.getType()) {
                last_entry.len += entry.len;
                entry.len = 0;
                keep_last = true;
            }
        }

        if (!keep_last) {
            last_idx = idx;
        }
    }
}

pub fn initRanges() !void {
    for (mmap_entries) |entry| {
        const ptr = entry.getPtr();
        const len = entry.getLen();
        const typ = PhysRangeType.fromMmapEntryType(entry.getType());
        if (len == 0) continue;
        const range: PhysMemRange = .{ .start = ptr, .length = len, .typ = typ };
        const list_item = try alloc.create(PhysMemRangeListItem);
        list_item.* = .{ .range = range };
        mm.memory_ranges.append(list_item);
        mm.total_memory += range.length;
        const list, const pages_count = blk: {
            if (typ == .free) {
                break :blk .{ &mm.free_ranges, &mm.free_pages_count };
            } else {
                break :blk .{ &mm.reserved_ranges, &mm.reserved_pages_count };
            }
        };

        const range_list_item = try alloc.create(PhysMemRangeListItem);
        range_list_item.* = .{ .range = range };
        list.append(range_list_item);
        pages_count.* += @divExact(len, arch.constants.default_page_size);

        if (typ == .free) {
            const phys_range_allocator = try alloc.create(PhysMemRangeAllocator);
            phys_range_allocator.* = .{
                .alloc = try .init(alloc, range.start, range.length),
                .region = range_list_item,
                .memory_start = range.start,
                .memory_len = range.length,
            };
            page_allocators.append(phys_range_allocator);
        }
    }
}

pub fn commitPages(count: PAddrSize) bool {
    mm.lock.lock();
    defer mm.lock.unlock();

    if (mm.uncommitted_pages_count < count) {
        return false;
    }

    mm.uncommitted_pages_count -= count;
    mm.committed_pages_count += count;
    return true;
}

pub fn uncommitPages(count: PAddrSize) void {
    mm.lock.lock();
    defer mm.lock.unlock();

    if (mm.committed_pages_count < count) {
        log.warn("Could not uncommit {d} pages. Not enough committed pages", .{count});
        return;
    }

    mm.committed_pages_count -= count;
    mm.uncommitted_pages_count += count;
}

pub fn allocatePages(count: PAddrSize, args: struct { committed: bool = false }) Error!PhysMemRange {
    // log.debug("allocating {d} pages", .{count});
    mm.lock.lock();
    defer mm.lock.unlock();

    if (args.committed) {
        mm.committed_pages_count -= count;
    } else {
        mm.uncommitted_pages_count -= count;
    }

    const requested_size = count * arch.constants.default_page_size;
    const alignment: std.mem.Alignment = .fromByteUnits(arch.constants.default_page_size);

    var allocators_iter = page_allocators.iter();
    while (allocators_iter.next()) |a| {
        if (a.canAlloc(requested_size, alignment)) {
            @branchHint(.likely);
            const std_alloc: std.mem.Allocator = a.allocator();
            const pages_ptr = std_alloc.rawAlloc(requested_size, alignment, 0);
            const pages_addr = @intFromPtr(pages_ptr);
            return .{ .start = pages_addr, .length = requested_size, .typ = .free };
            // FIXME: we lost tracking free ranges/committed pages here
        }
    }
    // return null;

    // var iter = mm.free_ranges.iter();
    // while (iter.next()) |list_item| {
    //     if (list_item.range.length == requested_size) {
    //         const range = list_item.range;
    //         mm.free_ranges.remove(list_item);
    //         alloc.destroy(list_item);
    //         return range;
    //     } else if (list_item.range.length > requested_size) {
    //         const range = PhysMemRange{ .start = list_item.range.start, .length = requested_size, .typ = .used };
    //         list_item.range.start += requested_size;
    //         list_item.range.length -= requested_size;
    //         return range;
    //     }
    // }
    return error.OutOfPhysMemory;
}

pub fn freePages(range: PhysMemRange) void {
    var allocators_iter = page_allocators.iter();
    const memory_addr = range.start;
    while (allocators_iter.next()) |a| {
        const allocator_mem_start = a.memory_start;
        const allocator_mem_end = allocator_mem_start + a.memory_len;
        if (allocator_mem_start <= memory_addr and memory_addr <= allocator_mem_end) {
            @branchHint(.likely);
            const std_alloc: std.mem.Allocator = a.allocator();
            const memory_ptr: [*]u8 = @ptrFromInt(memory_addr);
            std_alloc.rawFree(memory_ptr[0..range.length], .fromByteUnits(arch.constants.default_page_size), 0);
            return;
        }
    }
    unreachable;
}
