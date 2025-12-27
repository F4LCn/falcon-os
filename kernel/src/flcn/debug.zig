const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const native_endian = builtin.cpu.arch.endian();
const Dwarf = std.debug.Dwarf;
const BootInfo = @import("bootinfo.zig").BootInfo;

extern var bootinfo: BootInfo;

const log = std.log.scoped(.debug);
var debug_info: ?Dwarf = null;
var unwind_info: [std.enums.directEnumArrayLen(Dwarf.Unwind.Section, 0)]?Dwarf.Unwind = @splat(null);
var debug_alloc: std.mem.Allocator = undefined;

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return debug_alloc;
}

pub const SelfInfo = struct {
    debug_info: *?Dwarf,
    unwind_info: *[std.enums.directEnumArrayLen(Dwarf.Unwind.Section, 0)]?Dwarf.Unwind,
    // TODO: (low prio) Add a caching mechinery for unwind entries
    // (nice to have since when we get here shit went down already)

    pub const can_unwind = true;
    pub const UnwindContext = Dwarf.SelfUnwinder;
    pub const init: SelfInfo = .{ .debug_info = &debug_info, .unwind_info = &unwind_info };
    pub fn deinit(_: *SelfInfo, _: std.mem.Allocator) void {}
    pub fn getModuleName(_: *SelfInfo, _: std.mem.Allocator, _: usize) ![]const u8 {
        return "FLCNOS KERNEL";
    }
    pub fn getSymbol(si: *SelfInfo, alloc: std.mem.Allocator, address: usize) !std.debug.Symbol {
        if (si.debug_info) |di| {
            return di.getSymbol(alloc, native_endian, address);
        }
        return error.MissingDebugInfo;
    }
    pub fn unwindFrame(si: *SelfInfo, alloc: std.mem.Allocator, context: *UnwindContext) !usize {
        for (si.unwind_info) |*unwind_ptr| {
            if (unwind_ptr.* != null) {
                const unwind = &unwind_ptr.*.?;
                if (context.computeRules(alloc, unwind, 0, null)) |entry| {
                    return context.next(alloc, &entry);
                } else |err| switch (err) {
                    error.MissingDebugInfo => continue,
                    error.InvalidDebugInfo,
                    error.UnsupportedDebugInfo,
                    error.OutOfMemory,
                    => |e| return e,

                    error.EndOfStream,
                    error.StreamTooLong,
                    error.ReadFailed,
                    error.Overflow,
                    error.InvalidOpcode,
                    error.InvalidOperation,
                    error.InvalidOperand,
                    => return error.InvalidDebugInfo,

                    error.UnimplementedUserOpcode,
                    error.UnsupportedAddrSize,
                    => return error.UnsupportedDebugInfo,
                }
            }
        }
        return error.MissingDebugInfo;
    }
};

pub fn init(alloc: std.mem.Allocator) !void {
    log.info("Initializing debug info", .{});
    if (bootinfo.debug_info_ptr == 0) {
        log.debug("No debug info loaded", .{});
        return;
    }
    debug_alloc = alloc;
    const debug_sections: *const Sections = @ptrFromInt(bootinfo.debug_info_ptr);

    var dwarf_sections: Dwarf.SectionArray = @splat(null);
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
        };
        if (section.len != 0) {
            log.debug(
                \\ Section {t}:
                \\     paddr 0x{x}
                \\     vaddr 0x{x}
                \\     len {d}
            , .{ debug_section_id, section.paddr, section.vaddr, section.len });
            dwarf_sections[i] = .{
                .data = @as([*]const u8, @ptrFromInt(section.paddr))[0..section.len],
                .owned = true,
            };
        }
    }
    debug_info = .{
        .sections = dwarf_sections,
    };
    if (debug_info) |*di| {
        try Dwarf.open(di, alloc, native_endian);
    }

    for (@typeInfo(Dwarf.Unwind.Section).@"enum".fields, 0..) |_, i| {
        const unwind_section: Dwarf.Unwind.Section = @enumFromInt(i);
        const section = switch (unwind_section) {
            .eh_frame => debug_sections.eh_frame_hdr,
            .debug_frame => debug_sections.debug_frame,
        };
        if (section.len != 0) {
            log.debug(
                \\ Section {t}:
                \\     paddr 0x{x}
                \\     vaddr 0x{x}
                \\     len {d}
            , .{ unwind_section, section.paddr, section.vaddr, section.len });
            const data = @as([*]const u8, @ptrFromInt(section.paddr))[0..section.len];
            const header = try Dwarf.Unwind.EhFrameHeader.parse(section.vaddr, data, @sizeOf(usize), native_endian);
            unwind_info[i] = .initEhFrameHdr(header, section.vaddr, @ptrFromInt(header.eh_frame_vaddr));
            unwind_info[i].?.prepare(alloc, @sizeOf(usize), native_endian, true, false) catch |e| {
                log.err("failed to prepare unwind_info {t}", .{e});
                continue;
            };
        }
    }
}

fn EnumFieldPackedStruct(comptime E: type, comptime Data: type, comptime field_default: ?Data) type {
    @setEvalBranchQuota(1000);
    var field_names: [@typeInfo(E).@"enum".fields.len][]const u8 = undefined;
    var field_types: [@typeInfo(E).@"enum".fields.len]type = undefined;
    var field_attributes: [@typeInfo(E).@"enum".fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (&field_names, &field_types, &field_attributes, @typeInfo(E).@"enum".fields) |*field_name, *field_type, *field_attribute, enum_field| {
        field_name.* = enum_field.name;
        field_type.* = Data;
        field_attribute.* = .{ .default_value_ptr = if (field_default) |d| @as(?*const anyopaque, @ptrCast(&d)) else null };
    }
    return @Struct(.@"packed", null, &field_names, &field_types, &field_attributes);
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

pub const Stacktrace = struct {
    pub const StacktraceArgs = struct { cpu_context: ?std.debug.cpu_context.Native = null };
    pub const num_traces = options.num_stack_trace;
    addresses: [num_traces]usize = .{0} ** num_traces,
    index: usize = 0,

    pub fn initFromAddr(ret_addr: usize, args: StacktraceArgs) Stacktrace {
        var self: Stacktrace = .{};
        self.capture(ret_addr, .{ .cpu_context = args.cpu_context });
        return self;
    }

    pub fn capture(self: *@This(), ret_addr: usize, args: StacktraceArgs) void {
        // NOTE: this is actually important because we look for 0 to decide how deep we go in the stacktrace
        @memset(&self.addresses, 0);
        const cpu_context_ptr = if (args.cpu_context != null) &args.cpu_context.? else null;
        const stacktrace = std.debug.captureCurrentStackTrace(.{ .first_address = ret_addr, .context = cpu_context_ptr, .allow_unsafe_unwind = true }, &self.addresses);
        self.index = stacktrace.index;
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
    stack_trace: Stacktrace,
    writer: *std.Io.Writer,
) !void {
    if (debug_info) |*di| {
        var frame_index: usize = 0;
        var frames_left: usize = @min(stack_trace.index, stack_trace.addresses.len);

        if (frames_left == 0) {
            try writer.print("Empty stacktrace..\n", .{});
        }

        while (frames_left != 0) : ({
            frames_left -= 1;
            frame_index = (frame_index + 1) % stack_trace.addresses.len;
        }) {
            const return_address = stack_trace.addresses[frame_index];
            const symbol_address = return_address - 1;
            const symbol = try di.getSymbol(debug_alloc, native_endian, symbol_address);
            try printSourceAtAddress(writer, symbol.source_location, return_address - 1, symbol.name, symbol.compile_unit_name);
        }

        if (stack_trace.index > stack_trace.addresses.len) {
            const dropped_frames = stack_trace.index - stack_trace.addresses.len;

            try writer.print("({d} additional stack frames skipped...)\n", .{dropped_frames});
        }
    } else {
        return error.MissingDebugInfo;
    }
}

fn printSourceAtAddress(
    writer: *std.Io.Writer,
    source_location: ?std.debug.SourceLocation,
    address: usize,
    symbol_name: ?[]const u8,
    compile_unit_name: ?[]const u8,
) !void {
    if (source_location) |*sl| {
        try writer.print("{s}:{d}:{d}", .{ sl.file_name, sl.line, sl.column });
    } else {
        try writer.writeAll("???:?:?");
    }

    try writer.print(": 0x{x} in ", .{address});
    if (symbol_name) |sn| {
        try writer.print("{s} ", .{sn});
    } else {
        try writer.writeAll("??? ");
    }
    if (compile_unit_name) |cun| {
        try writer.print("({s})\n", .{cun});
    } else {
        try writer.writeAll("(???)\n");
    }
}
