const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const native_endian = builtin.cpu.arch.endian();
const Dwarf = std.debug.Dwarf;
const BootInfo = @import("bootinfo.zig").BootInfo;
const native_arch = builtin.cpu.arch;

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
    log.debug("Initializing debug info", .{});
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
    log.info("debug subsystem initialized", .{});
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

    const StackIterator = union(enum) {
        ctx_first: *const std.debug.cpu_context.Native,
        di: if (SelfInfo != void and SelfInfo.can_unwind and fp_usability != .ideal)
            SelfInfo.UnwindContext
        else
            noreturn,
        fp: usize,

        inline fn init(opt_context_ptr: ?*const std.debug.cpu_context.Native) StackIterator {
            if (opt_context_ptr) |context_ptr| {
                return .{ .ctx_first = context_ptr };
            }

            if (SelfInfo != void and
                SelfInfo.can_unwind and
                std.debug.cpu_context.Native != noreturn and
                fp_usability != .ideal)
            {
                return .{ .di = .init(&.current()) };
            }
            return .{
                .fp = if (native_arch.isSPARC()) sp: {
                    flushSparcWindows();
                    break :sp asm (""
                        : [_] "={o6}" (-> usize),
                    ) + stack_bias;
                } else @frameAddress(),
            };
        }

        noinline fn flushSparcWindows() void {
            // Flush all register windows except the current one (hence `noinline`). This ensures that
            // we actually see meaningful data on the stack when we walk the frame chain.
            if (comptime builtin.target.cpu.has(.sparc, .v9))
                asm volatile ("flushw" ::: .{ .memory = true })
            else
                asm volatile ("ta 3" ::: .{ .memory = true }); // ST_FLUSH_WINDOWS
        }

        fn deinit(si: *StackIterator) void {
            switch (si.*) {
                .ctx_first => {},
                .fp => {},
                .di => |*unwind_context| unwind_context.deinit(getDebugInfoAllocator()),
            }
        }

        const FpUsability = enum {
            useless,
            unsafe,
            safe,
            ideal,
        };

        const fp_usability: FpUsability = switch (builtin.target.cpu.arch) {
            .alpha,
            .avr,
            .csky,
            .microblaze,
            .microblazeel,
            .mips,
            .mipsel,
            .mips64,
            .mips64el,
            .msp430,
            .sh,
            .sheb,
            .xcore,
            => .useless,
            .hexagon,
            .powerpc,
            .powerpcle,
            .powerpc64,
            .powerpc64le,
            .sparc,
            .sparc64,
            => .ideal,
            .aarch64 => if (builtin.target.os.tag.isDarwin()) .safe else .unsafe,
            else => .unsafe,
        };

        fn stratOk(it: *const StackIterator, allow_unsafe: bool) bool {
            return switch (it.*) {
                .ctx_first, .di => true,
                .fp => switch (fp_usability) {
                    .useless => false,
                    .unsafe => allow_unsafe and !builtin.omit_frame_pointer,
                    .safe => !builtin.omit_frame_pointer,
                    .ideal => true,
                },
            };
        }

        const Result = union(enum) {
            frame: usize,
            end,
            switch_to_fp: struct {
                address: usize,
                err: std.debug.SelfInfoError,
            },
        };

        pub inline fn getSelfDebugInfo() !*SelfInfo {
            if (SelfInfo == void) return error.UnsupportedTarget;
            const S = struct {
                var self_info: SelfInfo = .init;
            };
            return &S.self_info;
        }

        fn next(it: *StackIterator) Result {
            switch (it.*) {
                .ctx_first => |context_ptr| {
                    it.* = if (SelfInfo != void and SelfInfo.can_unwind and fp_usability != .ideal)
                        .{ .di = .init(context_ptr) }
                    else
                        .{ .fp = context_ptr.getFp() };

                    return .{ .frame = context_ptr.getPc() +| 1 };
                },
                .di => |*unwind_context| {
                    const di = getSelfDebugInfo() catch unreachable;
                    const di_gpa = getDebugInfoAllocator();
                    const ret_addr = di.unwindFrame(di_gpa, unwind_context) catch |err| {
                        const pc = unwind_context.pc;
                        const fp = unwind_context.getFp();
                        it.* = .{ .fp = fp };
                        return .{ .switch_to_fp = .{
                            .address = pc,
                            .err = err,
                        } };
                    };
                    if (ret_addr <= 1) return .end;
                    return .{ .frame = ret_addr };
                },
                .fp => |fp| {
                    if (fp == 0) return .end;

                    const bp_addr = applyOffset(fp, fp_to_bp_offset) orelse return .end;
                    const ra_addr = applyOffset(fp, fp_to_ra_offset) orelse return .end;

                    if (bp_addr == 0 or !std.mem.isAligned(bp_addr, @alignOf(usize)) or
                        ra_addr == 0 or !std.mem.isAligned(ra_addr, @alignOf(usize)))
                    {
                        return .end;
                    }

                    const bp_ptr: *const usize = @ptrFromInt(bp_addr);
                    const ra_ptr: *const usize = @ptrFromInt(ra_addr);
                    const bp = applyOffset(bp_ptr.*, stack_bias) orelse return .end;

                    if (bp != 0 and switch (comptime builtin.target.stackGrowth()) {
                        .down => bp <= fp,
                        .up => bp >= fp,
                    }) return .end;

                    it.fp = bp;
                    const ra = stripInstructionPtrAuthCode(ra_ptr.*);
                    if (ra <= 1) return .end;
                    return .{ .frame = ra };
                },
            }
        }

        pub inline fn stripInstructionPtrAuthCode(ptr: usize) usize {
            if (native_arch.isAARCH64()) {
                return asm (
                    \\mov x16, x30
                    \\mov x30, x15
                    \\hint 0x07
                    \\mov x15, x30
                    \\mov x30, x16
                    : [ret] "={x15}" (-> usize),
                    : [ptr] "{x15}" (ptr),
                    : .{ .x16 = true });
            }

            return ptr;
        }

        const fp_to_bp_offset = off: {
            if (native_arch == .hppa) break :off -1 * @sizeOf(usize);
            if (native_arch == .hppa64) break :off -1 * @sizeOf(usize);
            if (native_arch.isLoongArch() or native_arch.isRISCV()) break :off -2 * @sizeOf(usize);
            if (native_arch == .or1k) break :off -2 * @sizeOf(usize);
            if (native_arch.isSPARC()) break :off 14 * @sizeOf(usize);
            break :off 0;
        };

        const fp_to_ra_offset = off: {
            if (native_arch == .hppa) break :off -5 * @sizeOf(usize);
            if (native_arch == .hppa64) break :off -2 * @sizeOf(usize);
            if (native_arch.isLoongArch() or native_arch.isRISCV()) break :off -1 * @sizeOf(usize);
            if (native_arch == .or1k) break :off -1 * @sizeOf(usize);
            if (native_arch.isPowerPC64()) break :off 2 * @sizeOf(usize);
            if (native_arch == .s390x) break :off 14 * @sizeOf(usize);
            if (native_arch.isSPARC()) break :off 15 * @sizeOf(usize);
            break :off @sizeOf(usize);
        };

        const stack_bias = bias: {
            if (native_arch == .sparc64) break :bias 2047;
            break :bias 0;
        };

        const ra_call_offset = off: {
            if (native_arch.isSPARC()) break :off 0;
            break :off 1;
        };

        fn applyOffset(addr: usize, comptime off: comptime_int) ?usize {
            if (off >= 0) return std.math.add(usize, addr, off) catch return null;
            return std.math.sub(usize, addr, -off) catch return null;
        }
    };
    pub fn initFromAddr(ret_addr: usize, args: StacktraceArgs) Stacktrace {
        var self: Stacktrace = .{};
        self.capture(ret_addr, .{ .cpu_context = args.cpu_context });
        return self;
    }

    pub fn capture(self: *@This(), ret_addr: usize, args: StacktraceArgs) void {
        // NOTE: this is actually important because we look for 0 to decide how deep we go in the stacktrace
        @memset(&self.addresses, 0);
        const cpu_context_ptr = if (args.cpu_context != null) &args.cpu_context.? else null;
        const stacktrace = captureCurrentStackTrace(.{ .first_address = ret_addr, .context = cpu_context_ptr, .allow_unsafe_unwind = true }, &self.addresses);
        self.index = stacktrace.index;
    }

    pub noinline fn captureCurrentStackTrace(opts: std.debug.StackUnwindOptions, addr_buf: []usize) std.builtin.StackTrace {
        const empty_trace: std.builtin.StackTrace = .{ .index = 0, .instruction_addresses = &.{} };
        if (!std.options.allow_stack_tracing) return empty_trace;
        var it: StackIterator = .init(opts.context);
        defer it.deinit();
        if (!it.stratOk(opts.allow_unsafe_unwind)) return empty_trace;

        var total_frames: usize = 0;
        var index: usize = 0;
        var wait_for = opts.first_address;
        while (index < addr_buf.len) switch (it.next()) {
            .switch_to_fp => if (!it.stratOk(opts.allow_unsafe_unwind)) break,
            .end => break,
            .frame => |ret_addr| {
                if (total_frames > 10_000) {
                    break;
                }
                total_frames += 1;
                if (wait_for) |target| {
                    if (ret_addr != target) continue;
                    wait_for = null;
                }
                addr_buf[index] = ret_addr;
                index += 1;
            },
        };
        return .{
            .index = index,
            .instruction_addresses = addr_buf[0..index],
        };
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
