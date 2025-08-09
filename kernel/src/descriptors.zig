const std = @import("std");
const pmem = @import("memory/pmem.zig");
const vmem = @import("memory/vmem.zig");
const constants = @import("constants.zig");

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
        system: bool = false,
        privilege: PrivilegeLevel = .ring0,
        present: bool = false,
        limit_upper: u4 = 0,
        avl: u1 = 0,
        is_64bit: bool = false,
        size: u1 = 0,
        granularity: Granularity = .bytes,
        base_upper: u8 = 0,

        pub fn create(args: struct {
            base: u32,
            limit: u20,
            typ: Type,
            system: bool = true,
            privilege: PrivilegeLevel = .ring0,
            present: bool = true,
            is_64bit: bool,
            size: u1,
            granularity: Granularity = .pages,
        }) @This() {
            const limit_lower: u16 = @truncate(args.limit);
            const limit_upper: u4 = @truncate(args.limit >> @typeInfo(u16).int.bits);
            const base_lower: u24 = @truncate(args.base);
            const base_upper: u8 = @truncate(args.base >> @typeInfo(u24).int.bits);

            return .{
                .limit_lower = limit_lower,
                .base_lower = base_lower,
                .typ = args.typ,
                .system = args.system,
                .privilege = args.privilege,
                .present = args.present,
                .limit_upper = limit_upper,
                .is_64bit = args.is_64bit,
                .size = args.size,
                .granularity = args.granularity,
                .base_upper = base_upper,
            };
        }
    };

    pub const Descriptor16Bytes = packed struct(u128) {
        limit_lower: u16,
        base_lower: u24,
        typ: Type,
        system: bool = false,
        privilege: PrivilegeLevel,
        present: bool,
        limit_upper: u4,
        avl: bool,
        is_64bit: bool = false,
        size: u1 = 0,
        granularity: Granularity,
        base_upper: u40,
        reserved: u32 = 0,

        pub fn create(args: struct {
            base: u64,
            limit: u20,
            typ: Type,
            system: bool = true,
            privilege: PrivilegeLevel = .ring0,
            present: bool = true,
            avl: bool,
            is_64bit: bool,
            size: u1,
            granularity: Granularity = .pages,
        }) @This() {
            const limit_lower: u16 = @truncate(args.limit);
            const limit_upper: u4 = @truncate(args.limit >> @typeInfo(u16).int.bits);
            const base_lower: u24 = @truncate(args.base);
            const base_upper: u40 = @truncate(args.base >> @typeInfo(u24).int.bits);

            return .{
                .limit_lower = limit_lower,
                .base_lower = base_lower,
                .typ = args.typ,
                .system = args.system,
                .privilege = args.privilege,
                .present = args.present,
                .limit_upper = limit_upper,
                .avl = args.avl,
                .is_64bit = args.is_64bit,
                .size = args.size,
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

// GDT [GDT header (base + limit)][entries]
// I want to build a gtd entry -> 8bytes descr -> builds one
fn GDT(num_entries: comptime_int) type {
    return extern struct {
        base: u32,
        limit: u16,
        const Self = @This();
        pub fn create(vm: *vmem) !*Self {
            const total_size_bytes = @sizeOf(Self) + num_entries * @sizeOf(Segment.Descriptor8Bytes);
            const page_count = @divExact(std.mem.alignForward(u64, total_size_bytes, constants.arch_page_size), constants.arch_page_size);
            const prange = pmem.allocatePage(page_count, .{}) orelse return error.PhysAllocationFailed;
            const vrange = vrange_blk: {
                const vrange = vm.allocateRange(prange.length, .{});
                try vm.mmap(prange, vrange, vmem.DefaultMmapFlags);
                break :vrange_blk vrange;
            };

            const allocated_bytes: [*]u8 = @ptrFromInt(@as(u64, @bitCast(vrange.start)));
            const allocated_slice = allocated_bytes[0..vrange.length];
            const self: *Self = @alignCast(std.mem.bytesAsValue(Self, allocated_slice[0..@sizeOf(Self)]));
            const gdt_entries = std.mem.bytesAsSlice(Segment.Descriptor8Bytes, allocated_slice[@sizeOf(Self)..]);

            gdt_entries[0] = .{};
            gdt_entries[1] = .create(.{
                .base = 0x0,
                .limit = std.math.maxInt(u16),
                .typ = Segment.KernelCodeType,
                .is_64bit = true,
                .size = 1,
            });
            gdt_entries[2] = .create(.{
                .base = 0x0,
                .limit = std.math.maxInt(u16),
                .typ = Segment.KernelDataType,
                .is_64bit = true,
                .size = 1,
            });
            gdt_entries[3] = .create(.{
                .base = 0x0,
                .limit = std.math.maxInt(u16),
                .typ = Segment.UserCodeType,
                .is_64bit = true,
                .size = 1,
            });
            gdt_entries[4] = .create(.{
                .base = 0x0,
                .limit = std.math.maxInt(u16),
                .typ = Segment.UserDataType,
                .is_64bit = true,
                .size = 1,
            });

            return self;
        }

        // pub fn insert_gdt_descriptor(self: *Self) void {
        //     _ = self;
        //     const allocated_bytes: [*]u8 = @ptrFromInt(@as(u64, @intCast(vrange.start)));
        //     const self: *Self = std.mem.bytesAsValue(Self, allocated_bytes[0..@sizeOf(Self)]);
        //     // const gdt_entries: []Segment.Descriptor8Bytes = std.mem.bytesAsSlice(Segment.Descriptor8Bytes, allocated_bytes[@sizeOf(Self)..]);
        // }

        pub fn load(self: *Self) void {
            // lgdt [self]
            asm volatile ("lgdt (%[addr])"
                :
                : [addr] "r" (self),
            );
        }
    };
}

// const IDT = struct {
//     const Self = @This();
//     pub fn create(base) !*Self {
//         // TODO: allocate page(s)
//         // create a GDT header
//     }

//     pub fn register_exception_handler(self: *Self) void {}

//     pub fn register_trap_handler(self: *Self) void {}

//     pub fn load(self: *Self) void {
//         // lidt
//     }
// };

pub fn init(vm: *vmem) !void {
    const gdt = try GDT(5).create(vm);
    gdt.load();
}
