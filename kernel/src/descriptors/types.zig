const std = @import("std");

pub const Segment = struct {
    pub const PrivilegeLevel = enum(u2) {
        ring0 = 0,
        ring1 = 1,
        ring2 = 2,
        ring3 = 3,
    };

    pub const DescriptorType = enum(u1) {
        system = 0,
        code_data = 1,
    };

    pub const Granularity = enum(u1) {
        bytes = 0,
        pages = 1,
    };

    pub const Selector = packed struct(u16) {
        privilege: PrivilegeLevel = .ring0,
        table_indicator: enum(u1) { GDT = 0, LDT = 1 } = .GDT,
        index: u13,
    };

    pub const Type = packed struct(u4) {
        accessed: bool = false,
        write_enabled: bool = false,
        expansion_direction: bool = false,
        code: bool = false,

        pub fn create(args: struct { accessed: bool = false, write_enabled: bool = true, expansion_direction: bool = false, code: bool = false }) @This() {
            return .{
                .accessed = args.accessed,
                .write_enabled = args.write_enabled,
                .expansion_direction = args.expansion_direction,
                .code = args.code,
            };
        }
    };

    const KernelCodeType = Type.create(.{ .code = true });
    const KernelDataType = Type.create(.{});
    const UserCodeType = Type.create(.{ .code = true });
    const UserDataType = Type.create(.{});

    pub const Descriptor8Bytes = packed struct(u64) {
        limit_lower: u16 = 0,
        base_lower: u24 = 0,
        typ: Type = .{},
        descriptor_type: DescriptorType = .system,
        privilege: PrivilegeLevel = .ring0,
        present: bool = false,
        limit_upper: u4 = 0,
        avl: u1 = 0,
        is_64bit: bool = false,
        default_size: u1 = 0,
        granularity: Granularity = .bytes,
        base_upper: u8 = 0,

        pub fn create(args: struct {
            base: u32,
            limit: u20,
            typ: Type,
            descriptor_type: DescriptorType = .code_data,
            privilege: PrivilegeLevel = .ring0,
            present: bool = true,
            is_64bit: bool,
            default_size: u1,
            granularity: Granularity = .pages,
        }) @This() {
            std.debug.assert((args.is_64bit and args.default_size == 0) or !args.is_64bit);

            const limit_lower: u16 = @truncate(args.limit);
            const limit_upper: u4 = @truncate(args.limit >> @typeInfo(u16).int.bits);
            const base_lower: u24 = @truncate(args.base);
            const base_upper: u8 = @truncate(args.base >> @typeInfo(u24).int.bits);

            return .{
                .limit_lower = limit_lower,
                .base_lower = base_lower,
                .typ = args.typ,
                .descriptor_type = args.descriptor_type,
                .privilege = args.privilege,
                .present = args.present,
                .limit_upper = limit_upper,
                .is_64bit = args.is_64bit,
                .default_size = args.default_size,
                .granularity = args.granularity,
                .base_upper = base_upper,
            };
        }
    };

    pub const Descriptor16Bytes = packed struct(u128) {
        limit_lower: u16,
        base_lower: u24,
        typ: Type,
        descriptor_type: DescriptorType = .system,
        privilege: PrivilegeLevel,
        present: bool,
        limit_upper: u4,
        avl: bool,
        is_64bit: bool = false,
        default_size: u1 = 0,
        granularity: Granularity,
        base_upper: u40,
        reserved: u32 = 0,

        pub fn create(args: struct {
            base: u64,
            limit: u20,
            typ: Type,
            descriptor_type: DescriptorType = .code_data,
            privilege: PrivilegeLevel = .ring0,
            present: bool = true,
            is_64bit: bool,
            default_size: u1,
            granularity: Granularity = .pages,
        }) @This() {
            std.debug.assert((args.is_64bit and args.default_size == 0) or !args.is_64bit);

            const limit_lower: u16 = @truncate(args.limit);
            const limit_upper: u4 = @truncate(args.limit >> @typeInfo(u16).int.bits);
            const base_lower: u24 = @truncate(args.base);
            const base_upper: u40 = @truncate(args.base >> @typeInfo(u24).int.bits);

            return .{
                .limit_lower = limit_lower,
                .base_lower = base_lower,
                .typ = args.typ,
                .descriptor_type = args.descriptor_type,
                .privilege = args.privilege,
                .present = args.present,
                .limit_upper = limit_upper,
                .avl = args.avl,
                .is_64bit = args.is_64bit,
                .default_size = args.default_size,
                .granularity = args.granularity,
                .base_upper = base_upper,
            };
        }
    };

    pub const TaskState = extern struct {
        reserved0: u32,
        rsp0: u64,
        rsp1: u64,
        rsp2: u64,
        reserved1: u64,
        ist1: u64,
        ist2: u64,
        ist3: u64,
        ist4: u64,
        ist5: u64,
        ist6: u64,
        ist7: u64,
        reserved2: u64,
        reserved3: u16,
        iomap_offset: u16,
    };
};
