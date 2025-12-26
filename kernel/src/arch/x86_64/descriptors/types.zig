const std = @import("std");
const common = @import("common.zig");
const ISR = @import("../interrupts.zig").ISR;

pub const Segment = struct {
    pub const PrivilegeLevel = enum(u2) {
        ring0 = 0,
        ring1 = 1,
        ring2 = 2,
        ring3 = 3,
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

    pub const SegmentType = packed struct(u4) {
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

    pub const KernelCodeType = SegmentType.create(.{ .code = true });
    pub const KernelDataType = SegmentType.create(.{});
    pub const UserCodeType = SegmentType.create(.{ .code = true });
    pub const UserDataType = SegmentType.create(.{});

    pub const GlobalDescriptor = packed struct(u64) {
        pub const Type = enum(u1) {
            system = 0,
            code_data = 1,
        };

        limit_lower: u16 = 0,
        base_lower: u24 = 0,
        typ: SegmentType = .{},
        descriptor_type: Type = .system,
        privilege: PrivilegeLevel = .ring0,
        present: bool = false,
        limit_upper: u4 = 0,
        avl: u1 = 0,
        is_64bit_code: bool = false,
        default_size: u1 = 0,
        granularity: Granularity = .bytes,
        base_upper: u8 = 0,

        pub fn create(args: struct {
            base: u32,
            limit: u20,
            typ: SegmentType,
            descriptor_type: Type = .code_data,
            privilege: PrivilegeLevel = .ring0,
            present: bool = true,
            is_64bit_code: bool,
            default_size: u1,
            granularity: Granularity = .pages,
        }) @This() {
            std.debug.assert((args.is_64bit_code and args.default_size == 0) or !args.is_64bit_code);

            std.debug.assert((args.is_64bit_code and args.typ.code == true) or !args.is_64bit_code);

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
                .is_64bit_code = args.is_64bit_code,
                .default_size = args.default_size,
                .granularity = args.granularity,
                .base_upper = base_upper,
            };
        }
    };

    pub const GateDescriptor = packed struct(u128) {
        pub const Type = enum(u4) {
            invalid_gate = 0,
            interrupt_gate = 14,
            trap_gate = 15,
        };

        offset_lower: u16 = 0,
        segment_selector: Segment.Selector = .{ .index = 0 },
        ist: u3 = 0,
        _unused0: u5 = 0,
        typ: Type,
        _unused1: u1 = 0,
        privilege: PrivilegeLevel = .ring0,
        present: bool = false,
        offset_upper: u48 = 0,
        _reserved: u32 = 0,

        pub fn create(args: struct {
            typ: Type,
            isr: ISR,
        }) @This() {
            const offset = @intFromPtr(args.isr);
            const offset_lower: u16 = @truncate(offset);
            const offset_upper: u48 = @truncate(offset >> @typeInfo(u16).int.bits);

            return .{
                .offset_lower = offset_lower,
                .segment_selector = common.kernel_code_segment_selector,
                .ist = 1,
                .typ = args.typ,
                .present = true,
                .offset_upper = offset_upper,
            };
        }
    };

    pub const TaskSegmentDescriptor = packed struct(u128) {
        pub const Type = enum(u4) {
            invalid = 0,
            tss_available = 9,
            tss_busy = 11,
        };

        limit_lower: u16,
        base_lower: u24,
        typ: Type,
        _unused0: u1 = 0,
        privilege: PrivilegeLevel = .ring0,
        present: bool = false,
        limit_upper: u4,
        _avl: u1 = 0,
        _unused1: u2 = 0,
        granularity: Granularity = .pages,
        base_upper: u40,
        _unused2: u32 = 0,

        pub fn create(args: struct {
            base: u64,
            limit: u20,
            typ: Type = .tss_available,
            privilege: PrivilegeLevel = .ring0,
            granularity: Granularity = .pages,
        }) @This() {
            const base_lower: u24 = @truncate(args.base);
            // TODO: make sure this is fine
            const base_upper: u40 = @truncate(args.base >> @typeInfo(u24).int.bits);

            const limit_lower: u16 = @truncate(args.limit);
            const limit_upper: u4 = @truncate(args.limit >> @typeInfo(u16).int.bits);

            return .{
                .limit_lower = limit_lower,
                .base_lower = base_lower,
                .typ = args.typ,
                .privilege = args.privilege,
                .present = true,
                .limit_upper = limit_upper,
                .granularity = args.granularity,
                .base_upper = base_upper,
            };
        }
    };

    pub const TaskState = packed struct {
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
