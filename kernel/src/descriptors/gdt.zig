const std = @import("std");
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
const max_tss_entries = 0;
const gdt_entries_size = @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries + @sizeOf(Segment.Descriptor16Bytes) * max_tss_entries;
gdt_entries_buffer: [gdt_entries_size]u8 align(16) = [_]u8{0} ** gdt_entries_size,
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

pub fn loadGDTR(self: *Self) void {
    self.gdtr = .{
        .limit = self.gdt_entries_buffer.len - 1,
        .base = &self.gdt_entries_buffer,
    };
    log.info("loading {*}", .{self.gdtr.base});
    asm volatile (
        \\lgdt (%[gdtr])
        :
        : [gdtr] "r" (@intFromPtr(&self.gdtr)),
    );
}

pub fn flushGDT(self: *Self) void {
    log.info("flushing data segment", .{});
    self.loadDataSegment(common.kernel_data_segment_selector);
    log.info("flushing code segment", .{});
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
