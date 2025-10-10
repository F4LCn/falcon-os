const std = @import("std");
const SpinLock = @import("synchronization.zig").SpinLock;
const DoublyLinkedList = @import("list.zig").DoublyLinkedList;

pub const VirtRangeType = enum(u8) {
    mmio,
    framebuffer,
    kernel,
    low_kernel,
    stack,
    quickmap,
    quickmap_pte,
    free,
};

pub fn VirtualMemoryManager(comptime TAddr: type, comptime TAddrSize: type, page_size: comptime_int) type {
    return struct {
        const Self = @This();
        const log = std.log.scoped(.vmm);
        const default_page_size = page_size;
        pub const VirtMemRange = struct {
            start: TAddr,
            length: u64,
            typ: ?VirtRangeType = null,
            frozen: bool = false,

            pub fn format(
                self: *const @This(),
                writer: *std.Io.Writer,
            ) !void {
                const start_addr = @as(u64, @bitCast(self.start));
                if (self.typ) |typ| {
                    try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) {s}]", .{ self, start_addr, start_addr +% self.length, self.length, @tagName(typ) });
                } else {
                    try writer.print("{*}[0x{X} -> 0x{X} (sz={X}) free]", .{ self, start_addr, start_addr +% self.length, self.length });
                }
            }
        };
        const VirtMemRangeListItem = struct {
            range: VirtMemRange,
            prev: ?*VirtMemRangeListItem = null,
            next: ?*VirtMemRangeListItem = null,

            pub fn format(
                self: *const @This(),
                writer: *std.Io.Writer,
            ) !void {
                try writer.print("{*}[range={f}]", .{ self, &self.range });
            }
        };
        const VirtMemRangeList = DoublyLinkedList(VirtMemRangeListItem, .prev, .next);

        const num_range_slots = std.enums.directEnumArrayLen(VirtRangeType, 0);

        alloc: std.mem.Allocator,
        lock: SpinLock,
        memory_map: [num_range_slots]VirtMemRangeList,
        free_ranges: VirtMemRangeList,
        reserved_ranges: VirtMemRangeList,
        quickmap_pt_entry: VirtMemRange,
        quickmap: VirtMemRange,

        pub fn init(alloc: std.mem.Allocator) Self {
            const zero: u64 = 0;
            return .{
                .lock = .create(),
                .alloc = alloc,
                .memory_map = [_]VirtMemRangeList{.{}} ** num_range_slots,
                .free_ranges = VirtMemRangeList{},
                .reserved_ranges = VirtMemRangeList{},
                .quickmap_pt_entry = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap_pte },
                .quickmap = .{ .start = @bitCast(zero), .length = 0, .typ = .quickmap },
            };
        }

        const RangeArgs = struct {
            typ: ?VirtRangeType = null,
            frozen: bool = false,
        };

        pub fn registerRange(self: *Self, start: TAddrSize, length: u64, args: RangeArgs) !void {
            const end = start +% length;
            const typ = args.typ orelse .free;
            log.debug("registering range 0x{x} -> 0x{x} ({d}) {t}", .{ start, end, length, typ });
            const range_list = &self.memory_map[@intFromEnum(typ)];
            var iter = range_list.iter();
            var prev_opt: ?*VirtMemRangeListItem = null;
            var next_opt: ?*VirtMemRangeListItem = null;
            while (iter.next()) |item| {
                const range = &item.range;
                log.debug("checking range: {f}", .{range});
                const range_start = @as(TAddrSize, @bitCast(range.start));
                // const range_end = range_start +% range.length;
                if (range_start <= start) {
                    prev_opt = item;
                    next_opt = item.next;
                    break;
                } else {
                    next_opt = item;
                    break;
                }
            }

            if (prev_opt == null and next_opt == null) {
                // This should only happen if no ranges are present
                std.debug.assert(range_list.head == null and range_list.tail == null);
                const range_item = try self.alloc.create(VirtMemRangeListItem);
                range_item.* = .{
                    .range = .{
                        .start = @bitCast(start),
                        .length = length,
                        .typ = typ,
                        .frozen = args.frozen,
                    },
                };
                range_list.append(range_item);
            } else if (prev_opt == null) {
                const n = next_opt.?; // Safety: we know this is non-null
                const n_range = &n.range;
                const n_start = @as(TAddrSize, @bitCast(n_range.start));
                if (n_start <= end) {
                    const overlap_length = end - n_start;
                    n_range.start = @bitCast(start);
                    n_range.length += length - overlap_length;
                    return;
                }
                const range_item = try self.alloc.create(VirtMemRangeListItem);
                range_item.* = .{
                    .range = .{
                        .start = @bitCast(start),
                        .length = length,
                        .typ = typ,
                        .frozen = args.frozen,
                    },
                };
                range_list.insertBefore(n, range_item);
            } else {
                const p = prev_opt.?; // Safety: we know this is non-null
                const p_range = &p.range;
                const p_start = @as(TAddrSize, @bitCast(p_range.start));
                const p_end = p_start +% p_range.length;
                if (p_end >= start) {
                    const overlap_length = p_end - start;
                    p_range.length += length - overlap_length;
                    if (next_opt) |n| {
                        const n_range = &n.range;
                        const n_start = @as(TAddrSize, @bitCast(n_range.start));
                        const new_p_end = p_start +% p_range.length;
                        if (new_p_end >= n_start) {
                            const pn_overlap_length = new_p_end - n_start;
                            p_range.length += n_range.length - pn_overlap_length;
                            range_list.remove(n);
                            defer self.alloc.destroy(n);
                        }
                    }
                    return;
                }
                const range_item = try self.alloc.create(VirtMemRangeListItem);
                range_item.* = .{
                    .range = .{
                        .start = @bitCast(start),
                        .length = length,
                        .typ = typ,
                        .frozen = args.frozen,
                    },
                };
                range_list.insertAfter(p, range_item);
            }
        }

        pub fn reserveRange(self: *Self, start: TAddrSize, length: u64, src_args: RangeArgs, dst_typ: VirtRangeType) !void {
            const end = start +% length;
            const src_typ = src_args.typ orelse .free;
            const free_ranges_list = &self.memory_map[@intFromEnum(src_typ)];
            var iter = free_ranges_list.iter();
            while (iter.next()) |item| {
                const range = &item.range;
                const range_start: TAddrSize = @bitCast(range.start);
                const range_end = range_start + range.length;
                if (range.frozen) continue;
                if (range_start <= start and range_end <= start) continue;
                if (range_start <= start and range_end >= end) {
                    // we are contained in range
                    const top_excess_length = start - range_start;
                    const bottom_excess_length = range_end - end;
                    if (top_excess_length == 0 and bottom_excess_length == 0) {
                        defer self.alloc.destroy(item);
                        defer free_ranges_list.remove(item);
                    } else if (top_excess_length > 0 and bottom_excess_length > 0) {
                        range.length = top_excess_length;
                        const end_range = try self.alloc.create(VirtMemRangeListItem);
                        end_range.* = .{
                            .range = .{
                                .start = @bitCast(end),
                                .length = bottom_excess_length,
                                .typ = range.typ,
                            },
                        };
                        free_ranges_list.insertAfter(item, end_range);
                    } else if (top_excess_length > 0) {
                        range.length = top_excess_length;
                    } else if (bottom_excess_length > 0) {
                        range.start = @bitCast(end);
                        range.length = bottom_excess_length;
                    } else {
                        // maybe we forgot a case ?
                        unreachable;
                    }
                } else if (range_start <= start) {
                    const overlap_length = range_end - start;
                    range.length -= overlap_length;
                } else if (range_end >= end) {
                    const overlap_length = end - range_start;
                    range.start = @bitCast(end);
                    range.length -= overlap_length;
                    break;
                }
            }
            try self.registerRange(start, length, .{ .typ = dst_typ });
        }

        pub fn allocateRange(self: *Self, count: TAddrSize, args: RangeArgs) !VirtMemRange {
            const length = count * page_size;
            const typ = args.typ orelse .free;
            const range_list = &self.memory_map[@intFromEnum(typ)];
            var iter = range_list.iter();
            while (iter.next()) |item| {
                var range = &item.range;
                if (range.length == length) {
                    range_list.remove(item);
                    defer self.alloc.destroy(item);
                    return range.*;
                } else if (range.length > length) {
                    const new_start: u64 = @as(u64, @bitCast(range.start)) + length;
                    const new_range = VirtMemRange{ .start = range.start, .length = length, .typ = typ };
                    range.start = @bitCast(new_start);
                    range.length -= length;
                    return new_range;
                }
            }

            return error.OutOfVirtMemory;
        }
    };
}
