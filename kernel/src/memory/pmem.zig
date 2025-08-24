const std = @import("std");
const constants = @import("constants");
const arch = @import("arch");
const BootInfo = @import("../bootinfo.zig").BootInfo;
const DoublyLinkedList = @import("../list.zig").DoublyLinkedList;
const SpinLock = @import("../synchronization.zig").SpinLock;
const Allocator = std.mem.Allocator;

extern var bootinfo: BootInfo;
var mmap_entries: []BootInfo.MmapEntry = undefined;

const log = std.log.scoped(.pmem);

const PhysRangeType = enum {
    used,
    free,
    acpi,
    reclaimable,
    bootinfo,
    framebuffer,
    kernel_module,
    paging,

    pub fn fromMmapEntryType(typ: BootInfo.MmapEntry.Type) @This() {
        // TODO: make this a bit more resilient
        return @enumFromInt(@intFromEnum(typ));
    }
};
const PAddr = u64;
pub const PhysMemRange = struct {
    start: PAddr,
    length: u64,
    type: PhysRangeType,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}]", .{ self, self.start, self.start + self.length, self.length, @tagName(self.type) });
    }
};
const PhysMemRangeListItem = struct {
    const Self = @This();
    range: PhysMemRange,
    prev: ?*Self = null,
    next: ?*Self = null,

    pub fn format(
        self: *const @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{*}[range={any}, p=0x{X}, n=0x{X}]", .{ self, &self.range, @intFromPtr(self.prev), @intFromPtr(self.next) });
    }
};
const PhysMemRangeList = DoublyLinkedList(PhysMemRangeListItem, .prev, .next);
const PhysicalMemoryManager = struct {
    const Self = @This();
    lock: SpinLock,
    alloc: Allocator,
    memory_ranges: PhysMemRangeList,
    free_ranges: PhysMemRangeList,
    reserved_ranges: PhysMemRangeList,
    total_memory: u64,
    free_pages_count: u64,
    reserved_pages_count: u64,
    uncommitted_pages_count: u64,
    committed_pages_count: u64,

    pub fn init(alloc: Allocator) Self {
        return .{
            .lock = .create(),
            .alloc = alloc,
            .memory_ranges = PhysMemRangeList{},
            .free_ranges = PhysMemRangeList{},
            .reserved_ranges = PhysMemRangeList{},
            .total_memory = 0,
            .free_pages_count = 0,
            .reserved_pages_count = 0,
            .uncommitted_pages_count = 0,
            .committed_pages_count = 0,
        };
    }
};

var mm: PhysicalMemoryManager = undefined;

pub fn init(alloc: Allocator) !void {
    mm = .init(alloc);
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

pub fn printFreeRanges() void {
    var iter = mm.free_ranges.iter();
    while (iter.next()) |list_item| {
        log.debug("{any}", .{list_item});
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
            entry.* = BootInfo.MmapEntry.create(entry.getPtr(), entry.getSize(), .FREE);
        }

        if (last_idx) |li| {
            const last_entry = &mmap_entries[li];
            if (last_entry.getEnd() == entry.getPtr() and last_entry.getType() == entry.getType()) {
                last_entry.size += entry.size;
                entry.size = 0;
                keep_last = true;
            }
        }

        if (!keep_last) {
            last_idx = idx;
        }
    }
}

fn initRanges() !void {
    for (mmap_entries) |entry| {
        const ptr = entry.getPtr();
        const size = entry.getSize();
        const typ = PhysRangeType.fromMmapEntryType(entry.getType());
        if (size == 0) continue;
        const range: PhysMemRange = .{ .start = ptr, .length = size, .type = typ };
        const list_item = try mm.alloc.create(PhysMemRangeListItem);
        list_item.* = .{ .range = range };
        mm.memory_ranges.append(list_item);
        mm.total_memory += range.length;
        if (typ == .free) {
            const free_list_item = try mm.alloc.create(PhysMemRangeListItem);
            free_list_item.* = .{ .range = range };
            mm.free_ranges.append(free_list_item);
            mm.free_pages_count += @divExact(size, arch.constants.default_page_size);
        } else {
            const reserved_list_item = try mm.alloc.create(PhysMemRangeListItem);
            reserved_list_item.* = .{ .range = range };
            mm.reserved_ranges.append(reserved_list_item);
            mm.reserved_pages_count += @divExact(size, arch.constants.default_page_size);
        }
    }
}

pub fn commitPages(count: u64) bool {
    mm.lock.lock();
    defer mm.lock.unlock();

    if (mm.uncommitted_pages_count < count) {
        return false;
    }

    mm.uncommitted_pages_count -= count;
    mm.committed_pages_count += count;
    return true;
}

pub fn uncommitPages(count: u64) void {
    mm.lock.lock();
    defer mm.lock.unlock();

    if (mm.committed_pages_count < count) {
        log.warn("Could not uncommit {d} pages. Not enough committed pages", .{count});
        return;
    }

    mm.committed_pages_count -= count;
    mm.uncommitted_pages_count += count;
}

pub fn allocatePage(count: u64, args: struct { committed: bool = false, zero: bool = true }) ?PhysMemRange {
    mm.lock.lock();
    defer mm.lock.unlock();

    if (args.committed) {
        mm.committed_pages_count -= count;
    } else {
        mm.uncommitted_pages_count -= count;
    }

    const requested_size = count * arch.constants.default_page_size;
    var iter = mm.free_ranges.iter();
    var range: ?PhysMemRange = null;
    while (iter.next()) |list_item| {
        if (list_item.range.length == requested_size) {
            range = list_item.range;
            mm.free_ranges.remove(list_item);
            mm.alloc.destroy(list_item);
            return range;
        } else if (list_item.range.length > requested_size) {
            range = .{ .start = list_item.range.start, .length = requested_size, .type = .used };
            list_item.range.start += requested_size;
            list_item.range.length -= requested_size;
            return range;
        }
    }

    if (args.zero) {
        if (range) |r| {
            _ = r;

            // FIXME: this will crash if we don't virtual map the memory region before writing to it
            // const ptr: [*]u8 = @ptrFromInt(r.start);
            // const slice = ptr[0..requested_size];
            // @memset(slice, 0);
        }
    }

    return range;
}

pub fn freePages(range: PhysMemRange) void {
    _ = range;
}
