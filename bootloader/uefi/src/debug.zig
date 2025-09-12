const std = @import("std");

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
