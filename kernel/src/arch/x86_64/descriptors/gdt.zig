const std = @import("std");
const options = @import("options");
const constants = @import("../constants.zig");
const Segment = @import("types.zig").Segment;
const builtin = @import("builtin");
const common = @import("common.zig");

const log = std.log.scoped(.gdt);

const Self = @This();
const GDTR = packed struct {
    limit: u16,
    base: *[gdt_entries_size]u8,
};
const max_gdt_entries = 5;
const max_tsd_entries = options.max_cpu;
const gdt_entries_size = @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries + @sizeOf(Segment.TaskSegmentDescriptor) * max_tsd_entries;
gdt_entries_buffer: [gdt_entries_size]u8 align(16) = [_]u8{0} ** gdt_entries_size,
tss_entries: [max_tsd_entries]Segment.TaskState = [_]Segment.TaskState{std.mem.zeroes(Segment.TaskState)} ** max_tsd_entries,
gdtr: GDTR = undefined,

pub fn create() Self {
    var _gdt: Self = .{};
    var gdt_entries = std.mem.bytesAsSlice(Segment.GlobalDescriptor, _gdt.gdt_entries_buffer[0 .. @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries]);

    gdt_entries[0] = .{};
    gdt_entries[1] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u20),
        .typ = Segment.KernelCodeType,
        .privilege = .ring0,
        .is_64bit_code = true,
        .default_size = 0,
    });
    gdt_entries[2] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u20),
        .typ = Segment.KernelDataType,
        .privilege = .ring0,
        .is_64bit_code = false,
        .default_size = 1,
    });
    gdt_entries[3] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u20),
        .typ = Segment.UserCodeType,
        .privilege = .ring3,
        .is_64bit_code = true,
        .default_size = 0,
    });
    gdt_entries[4] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u20),
        .typ = Segment.UserDataType,
        .privilege = .ring3,
        .is_64bit_code = false,
        .default_size = 1,
    });

    return _gdt;
}

pub fn fillGDTR(self: *Self) void {
    log.debug("filling GDTR", .{});
    self.gdtr = .{
        .limit = self.gdt_entries_buffer.len - 1,
        .base = &self.gdt_entries_buffer,
    };
}

pub fn fillTss(self: *Self, stacks: *[max_tsd_entries * constants.default_page_size]u8) void {
    log.debug("filling TSS", .{});
    const tsd_entries_buffer = self.gdt_entries_buffer[@sizeOf(Segment.GlobalDescriptor) * max_gdt_entries ..];
    var tsd_entries = std.mem.bytesAsSlice(Segment.TaskSegmentDescriptor, tsd_entries_buffer[0 .. @sizeOf(Segment.TaskSegmentDescriptor) * max_tsd_entries]);

    inline for (0..max_tsd_entries) |tsd_idx| {
        tsd_entries[tsd_idx] = .create(.{
            .base = @intFromPtr(&self.tss_entries[tsd_idx]),
            .limit = @sizeOf(Segment.TaskState) - 1,
        });
    }

    inline for (0..max_tsd_entries) |tsd_idx| {
        const stack_start_addr = @intFromPtr(stacks) + stacks.len - tsd_idx * constants.default_page_size;
        self.tss_entries[tsd_idx].ist1 = stack_start_addr;
        self.tss_entries[tsd_idx].iomap_offset = std.math.maxInt(u16);
    }
}

pub fn loadGDTR(self: *Self) void {
    log.debug("loading GDTR {*}", .{self.gdtr.base});
    asm volatile (
        \\lgdt (%[gdtr])
        :
        : [gdtr] "r" (@intFromPtr(&self.gdtr)),
    );
}

pub fn loadTR(self: *Self, args: struct { cpu_id: u32 = 0 }) void {
    _ = self;
    const tss_selector = @as(u16, @bitCast(Segment.Selector{ .index = max_gdt_entries + @as(u13, @truncate(args.cpu_id)) }));
    log.debug("loading TR 0x{X}", .{tss_selector});
    asm volatile (
        \\ltr %[tss_selector]
        :
        : [tss_selector] "r" (tss_selector),
    );
}

pub fn flushGDT(self: *Self) void {
    log.debug("flushing data segment", .{});
    self.loadDataSegment(common.kernel_data_segment_selector);
    log.debug("flushing code segment", .{});
    self.loadCodeSegment(common.kernel_code_segment_selector);
}

fn loadDataSegment(self: *Self, segment_selector: Segment.Selector) void {
    if (builtin.mode == .Debug) {
        if (segment_selector.table_indicator == .GDT) {
            const gdt_entries = std.mem.bytesAsSlice(Segment.GlobalDescriptor, self.gdt_entries_buffer[0 .. @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries]);
            const selected_entry: Segment.GlobalDescriptor = gdt_entries[segment_selector.index];
            std.debug.assert(selected_entry.typ.code == false);
        }
    }

    const ds_selector =
        if (builtin.mode == .Debug) @as(u16, @bitCast(common.kernel_data_segment_selector)) else @as(u16, @bitCast(segment_selector));

    asm volatile (
        \\ movw %[ds_selector], %%ds
        \\ movw %[ds_selector], %%es
        \\ movw %[ds_selector], %%fs
        \\ movw %[ds_selector], %%gs
        \\ movw %[ds_selector], %%ss
        :
        // TODO: check that this behaves ok
        : [ds_selector] "r" (ds_selector),
    );
}

fn loadCodeSegment(self: *Self, segment_selector: Segment.Selector) void {
    if (builtin.mode == .Debug) {
        if (segment_selector.table_indicator == .GDT) {
            const gdt_entries = std.mem.bytesAsSlice(Segment.GlobalDescriptor, self.gdt_entries_buffer[0 .. @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries]);
            const selected_entry: Segment.GlobalDescriptor = gdt_entries[segment_selector.index];
            std.debug.assert(selected_entry.typ.code == true);
        }
    }

    const cs_selector =
        if (builtin.mode == .Debug) @as(u16, @bitCast(common.kernel_code_segment_selector)) else @as(u16, @bitCast(segment_selector));

    asm volatile (
        \\pushq %[cs_selector]
        \\leaq .jmp_offset(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\.jmp_offset:
        :
        : [cs_selector] "n" (cs_selector),
        : .{ .rax = true });
}
