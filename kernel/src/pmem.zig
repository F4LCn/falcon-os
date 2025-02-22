const std = @import("std");
const BootInfo = @import("bootinfo.zig").BootInfo;
const DoublyLinkedList = @import("list.zig").DoublyLinkedList;
const SpinLock = @import("synchronization.zig").SpinLock;

extern var bootinfo: BootInfo;
var mmap_entries: []BootInfo.MmapEntry = undefined;

const log = std.log.scoped(.pmem);

const PAddr = u64;
const PhysMemRange = struct {
    start: PAddr,
    length: u64,
};
const PhysMemRangeListItem = struct {
    const Self = @This();
    range: PhysMemRange,
    prev: ?*Self,
    next: ?*Self,
};
const PhysMemRangeList = DoublyLinkedList(PhysMemRangeListItem, .prev, .next);
const PhysicalMemoryManager = struct {
    const Self = @This();
    lock: SpinLock,
    memory_ranges: PhysMemRangeList,
    free_ranges: PhysMemRangeList,
    reserved_ranges: PhysMemRangeList,
    free_pages_count: u64,
    reserved_pages_count: u64,
    uncommited_pages_count: u64,
    commited_pages_count: u64,

    pub fn init() Self {
        return .{
            .lock = .create(),
            .memory_ranges = PhysMemRangeList{},
            .free_ranges = PhysMemRangeList{},
            .reserved_ranges = PhysMemRangeList{},
            .free_pages_count = 0,
            .reserved_pages_count = 0,
            .uncommited_pages_count = 0,
            .commited_pages_count = 0,
        };
    }
};

var mm: PhysicalMemoryManager = undefined;

pub fn init() void {
    mm = .init();
    mm.lock.lock();
    defer mm.lock.unlock();

    log.debug("bootinfo ptr: {*}, size: {d}", .{&bootinfo, bootinfo.size});
    const mmaps: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    // bootinfo size - bootinfo header size = mmap size (total) / sizeof(mmap) => mmap count
    const bootinfo_header_size = @intFromPtr(mmaps) - @intFromPtr(&bootinfo);
    log.debug("bootinfo header size: expecting 96B : got {d}B", .{bootinfo_header_size});
    const mmap_size = bootinfo.size - bootinfo_header_size;
    log.debug("mmap size is: {d}, size of an mmap entry {d}", .{mmap_size, @sizeOf(BootInfo.MmapEntry)});
    const mmap_count = @divExact(mmap_size, @sizeOf(BootInfo.MmapEntry));
    log.debug("mmap count: {d}", .{mmap_count});
    mmap_entries = mmaps[0..mmap_count];

    reclaimFreeableMemory();
    initRanges();

    mm.uncommited_pages_count = mm.free_pages_count;
}

fn reclaimFreeableMemory() void {
    for(mmap_entries) |*entry| {
        if (entry.getType() != .RECLAIMABLE) continue;
        entry.* = BootInfo.MmapEntry.create(entry.getPtr(), entry.getSize(), .FREE);
    }
}

fn initRanges() void {

}

pub fn commitPages(count: u64) bool {
    _ = count;
}

pub fn uncommitPages(count: u64) void {
    _ = count;
}

pub fn allocatePage(count: u64, args: struct { commited: bool, zero: bool }) PhysMemRange {
    _ = count;
    _ = args;
}

pub fn freePages(range: PhysMemRange) void {
    _ = range;
}
