const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();
const Dwarf = std.debug.Dwarf;
const BootInfo = @import("bootinfo.zig").BootInfo;

// TODO: on the bootloaders side
// debug info should be loaded by the bootloader if the relevant sections exist
// in the elf binary. A new field should be added to the bootinfo struct pointing to a mapped page
// containing the debug info (parsed? prob not just load the sections into memory and we'll read them).

// NOTE: Design goals ..
// This module should handle parsing the dwarf data from debug sections and provide an API that
// lets us find a symbol (variable/function/module) given an address (a stack trace entry for example)

extern var bootinfo: BootInfo;

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

const log = std.log.scoped(.debug);

pub fn init(alloc: std.mem.Allocator) !void {
    if (bootinfo.debug_info_ptr == 0) {
        log.debug("No debug info loaded", .{});
        return;
    }

    const debug_info: *const Sections = @ptrFromInt(bootinfo.debug_info_ptr);

    var sections: Dwarf.SectionArray = Dwarf.null_section_array;
    inline for (@typeInfo(Dwarf.Section.Id).@"enum".fields, 0..) |_, i| {
        const debug_section_id: Dwarf.Section.Id = @enumFromInt(i);
        const section: Section = switch (debug_section_id) {
            .debug_info => debug_info.debug_info,
            .debug_abbrev => debug_info.debug_abbrev,
            .debug_str => debug_info.debug_str,
            .debug_str_offsets => debug_info.debug_str_offsets,
            .debug_line => debug_info.debug_line,
            .debug_line_str => debug_info.debug_line_str,
            .debug_ranges => debug_info.debug_ranges,
            .debug_loclists => debug_info.debug_loclists,
            .debug_rnglists => debug_info.debug_rnglists,
            .debug_addr => debug_info.debug_addr,
            .debug_names => debug_info.debug_names,
            .debug_frame => debug_info.debug_frame,
            .eh_frame => debug_info.eh_frame,
            .eh_frame_hdr => debug_info.eh_frame_hdr,
        };
        if (section.len != 0) {
            sections[i] = .{
                .data = @as([*]const u8, @ptrFromInt(section.paddr))[0..section.len],
                .virtual_address = section.vaddr,
                .owned = true,
            };
        }
    }
    var dwarf: Dwarf = .{
        .endian = native_endian,
        .sections = sections,
        .is_macho = false,
    };
    try Dwarf.open(&dwarf, alloc);

    const symbol = try dwarf.getSymbol(alloc, @intFromPtr(&init));
    log.info(
        \\ symbol name: {s}
        \\ filename: {s}
        \\ line: {d}
    , .{ symbol.name, symbol.source_location.?.file_name, symbol.source_location.?.line });
}
