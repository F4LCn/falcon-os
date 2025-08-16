const std = @import("std");
const Segment = @import("types.zig").Segment;
const builtin = @import("builtin");
const common = @import("common.zig");

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

pub fn init() Self {
    var _gdt: Self = .{};
    var gdt_entries = std.mem.bytesAsSlice(Segment.GlobalDescriptor, _gdt.gdt_entries_buffer[0 .. @sizeOf(Segment.GlobalDescriptor) * max_gdt_entries]);

    gdt_entries[0] = .{};
    gdt_entries[1] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u16),
        .typ = Segment.KernelCodeType,
        .is_64bit = true,
        .default_size = 0,
    });
    gdt_entries[2] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u16),
        .typ = Segment.KernelDataType,
        .is_64bit = true,
        .default_size = 0,
    });
    gdt_entries[3] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u16),
        .typ = Segment.UserCodeType,
        .privilege = .ring3,
        .is_64bit = true,
        .default_size = 0,
    });
    gdt_entries[4] = .create(.{
        .base = 0x0,
        .limit = std.math.maxInt(u16),
        .typ = Segment.UserDataType,
        .privilege = .ring3,
        .is_64bit = true,
        .default_size = 0,
    });

    _gdt.gdtr = .{
        .limit = _gdt.gdt_entries_buffer.len - 1,
        .base = &_gdt.gdt_entries_buffer,
    };

    _gdt.loadGDTR();
    _gdt.flushGDT();

    return _gdt;
}

fn loadGDTR(self: *Self) void {
    asm volatile (
        \\lgdt (%[gdtr])
        :
        : [gdtr] "r" (@intFromPtr(&self.gdtr)),
    );
}

fn flushGDT(self: *Self) void {
    self.loadDataSegment(common.kernel_data_segment_selector);
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

    asm volatile (
        \\ mov %[ds_selector], %%ds
        \\ mov %[ds_selector], %%es
        \\ mov %[ds_selector], %%fs
        \\ mov %[ds_selector], %%gs
        \\ mov %[ds_selector], %%ss
        :
        // TODO: check that this behaves ok
        : [ds_selector] "r" (@as(u16, @bitCast(segment_selector))),
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

    asm volatile (
        \\mov %[cs_selector], %%rax
        \\pushq %%rax
        \\leaq .jmp_offset(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\.jmp_offset:
        :
        : [cs_selector] "n" (@as(u16, @bitCast(segment_selector))),
        : "rax"
    );
}
