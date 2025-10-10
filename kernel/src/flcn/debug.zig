const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const native_endian = builtin.cpu.arch.endian();
const Dwarf = std.debug.Dwarf;
const BootInfo = @import("bootinfo.zig").BootInfo;

extern var bootinfo: BootInfo;

const log = std.log.scoped(.debug);
var debug_info: ?Dwarf = null;
var debug_alloc: ?std.mem.Allocator = null;

pub fn init(alloc: std.mem.Allocator) !void {
    log.info("Initializing debug info", .{});
    if (bootinfo.debug_info_ptr == 0) {
        log.debug("No debug info loaded", .{});
        return;
    }
    debug_alloc = alloc;
    const debug_sections: *const Sections = @ptrFromInt(bootinfo.debug_info_ptr);

    var dwarf_sections: Dwarf.SectionArray = Dwarf.null_section_array;
    inline for (@typeInfo(Dwarf.Section.Id).@"enum".fields, 0..) |_, i| {
        const debug_section_id: Dwarf.Section.Id = @enumFromInt(i);
        const section: Section = switch (debug_section_id) {
            .debug_info => debug_sections.debug_info,
            .debug_abbrev => debug_sections.debug_abbrev,
            .debug_str => debug_sections.debug_str,
            .debug_str_offsets => debug_sections.debug_str_offsets,
            .debug_line => debug_sections.debug_line,
            .debug_line_str => debug_sections.debug_line_str,
            .debug_ranges => debug_sections.debug_ranges,
            .debug_loclists => debug_sections.debug_loclists,
            .debug_rnglists => debug_sections.debug_rnglists,
            .debug_addr => debug_sections.debug_addr,
            .debug_names => debug_sections.debug_names,
            .debug_frame => debug_sections.debug_frame,
            .eh_frame => debug_sections.eh_frame,
            .eh_frame_hdr => debug_sections.eh_frame_hdr,
        };
        if (section.len != 0) {
            dwarf_sections[i] = .{
                .data = @as([*]const u8, @ptrFromInt(section.paddr))[0..section.len],
                .virtual_address = section.vaddr,
                .owned = true,
            };
        }
    }
    debug_info = .{
        .endian = native_endian,
        .sections = dwarf_sections,
        .is_macho = false,
    };
    if (debug_info) |*di| {
        try Dwarf.open(di, alloc);
        try di.scanAllUnwindInfo(alloc, 0);
    }
}

fn EnumFieldPackedStruct(comptime E: type, comptime Data: type, comptime field_default: ?Data) type {
    @setEvalBranchQuota(1000);
    var struct_fields: [@typeInfo(E).@"enum".fields.len]std.builtin.Type.StructField = undefined;
    for (&struct_fields, @typeInfo(E).@"enum".fields) |*struct_field, enum_field| {
        struct_field.* = .{
            .name = enum_field.name,
            .type = Data,
            .default_value_ptr = if (field_default) |d| @as(?*const anyopaque, @ptrCast(&d)) else null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .@"packed",
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub const Section = packed struct {
    const num_types = std.enums.directEnumArrayLen(Type, 0) - 1;
    pub const Type = enum(u8) {
        debug_info,
        debug_abbrev,
        debug_str,
        debug_str_offsets,
        debug_line,
        debug_line_str,
        debug_ranges,
        debug_loclists,
        debug_rnglists,
        debug_addr,
        debug_names,
        debug_frame,
        eh_frame,
        eh_frame_hdr,
    };

    paddr: u64 = 0,
    len: u64 = 0,
    vaddr: u64 = undefined,
};

pub const Sections = EnumFieldPackedStruct(Section.Type, Section, .{});

pub const StackTrace = struct {
    const num_traces = options.num_stack_trace;
    addresses: [num_traces]usize = .{0} ** num_traces,
    index: usize = 0,

    pub fn capture(self: *@This(), ret_addr: usize) void {
        // NOTE: this is actually important because we look for 0 to decide how deep we go in the stacktrace
        @memset(&self.addresses, 0);
        var it = std.debug.StackIterator.init(ret_addr, @frameAddress());
        defer it.deinit();
        for (&self.addresses, 0..) |*addr, i| {
            addr.* = it.next() orelse {
                self.index = i;
                return;
            };
        }
        self.index = self.addresses.len;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // TODO: maybe extract test-specific behavior elsewhere ??
        if (builtin.is_test) {
            var addresses: [num_traces]usize = .{0} ** num_traces;
            @memcpy(&addresses, &self.addresses);
            const std_stacktrace: std.builtin.StackTrace = .{ .instruction_addresses = &addresses, .index = self.index };
            try std_stacktrace.format(writer);
            return;
        }

        writeStackTrace(self, writer) catch |err| {
            try writer.print("Unable to print stack trace: {s}\n", .{@errorName(err)});
        };
    }
};

pub fn writeStackTrace(
    stack_trace: StackTrace,
    writer: *std.Io.Writer,
) !void {
    if (debug_info) |*di| {
        var frame_index: usize = 0;
        var frames_left: usize = @min(stack_trace.index, stack_trace.addresses.len);

        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index = (frame_index + 1) % stack_trace.addresses.len;
        }) {
            const return_address = stack_trace.addresses[frame_index];
            const symbol_address = return_address - 1;
            const symbol = try di.getSymbol(debug_alloc orelse return, symbol_address);
            try printSourceAtAddress(writer, symbol.source_location, return_address - 1, symbol.name, symbol.compile_unit_name);
        }

        if (stack_trace.index > stack_trace.addresses.len) {
            const dropped_frames = stack_trace.index - stack_trace.addresses.len;

            try writer.print("({d} additional stack frames skipped...)\n", .{dropped_frames});
        }
    } else {
        return error.NoDebugInfo;
    }
}

fn printSourceAtAddress(
    writer: *std.Io.Writer,
    source_location: ?std.debug.SourceLocation,
    address: usize,
    symbol_name: []const u8,
    compile_unit_name: []const u8,
) !void {
    if (source_location) |*sl| {
        try writer.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column });
    } else {
        try writer.writeAll("???:?:?");
    }

    try writer.print(": 0x{x} in {s} ({s})\n", .{ address, symbol_name, compile_unit_name });
}
