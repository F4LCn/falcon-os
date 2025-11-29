const std = @import("std");

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
