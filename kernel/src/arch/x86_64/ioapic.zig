const std = @import("std");
const constants = @import("constants.zig");
const memory = @import("memory.zig");
const smp = @import("smp.zig");
const options = @import("options");

const log = std.log.scoped(.ioapic);

const IoApicDriver = struct {
    const register_select_offset = 0x00;
    const window_offset = 0x10;
    const Register = enum(u8) {
        id = 0x0,
        version = 0x1,
        arb_id = 0x2,
        redirection_table = 0x10,
    };

    _base_phys_addr: u32,
    base_addr: memory.VAddr,
    register_select: *volatile u32,
    window: *volatile u32,
    gsi_base: u32,

    pub fn init(base_addr: u32, gsi_base: u32, page_map: *memory.PageMapManager) !IoApicDriver {
        log.debug("initializing ioapic (base: 0x{x})", .{base_addr});
        const ioapic_base = page_map.physToVirt(base_addr);
        log.debug("mapped ioapic base to 0x{x}", .{ioapic_base.toAddr()});
        try page_map.mmap(
            .{
                .start = base_addr,
                .length = constants.default_page_size,
                .typ = .acpi,
            },
            .{
                .start = ioapic_base,
                .length = constants.default_page_size,
            },
            memory.DefaultFlags.extend(.{
                .read_write = .read_write,
                .cache_control = .uncacheable,
            }),
            .{ .remap = true },
        );

        return .{
            ._base_phys_addr = base_addr,
            .base_addr = ioapic_base,
            .register_select = @ptrFromInt(ioapic_base.toAddr() + register_select_offset),
            .window = @ptrFromInt(ioapic_base.toAddr() + window_offset),
            .gsi_base = gsi_base,
        };
    }

    pub fn id(self: IoApicDriver) u32 {
        const id_reg = self.read(.id);
        return (id_reg >> 24) & 0xf;
    }

    fn read(self: IoApicDriver, reg: Register) u32 {
        const reg_offset = @intFromEnum(reg);
        self.register_select.* = reg_offset;
        // log.debug("reading {t}@{*}: {x}", .{ reg, self.window, self.window.* });
        return self.window.*;
    }

    pub fn write(self: IoApicDriver, reg: Register, val: u32) void {
        const reg_offset = @intFromEnum(reg);
        self.register_select.* = reg_offset;

        self.window.* = val;
        // log.debug("wrote {t}@{*}: {x}", .{ reg, self.window, self.window.* });
    }
};

var drivers_buf: [options.max_cpu]IoApicDriver = .{undefined} ** options.max_cpu;
var drivers: std.ArrayList(IoApicDriver) = .initBuffer(&drivers_buf);
pub fn init(ioapics: []smp.IoApic, page_map: *memory.PageMapManager) !void {
    for (ioapics) |ioapic| {
        const driver: IoApicDriver = try .init(ioapic.address, ioapic.gsi_base, page_map);
        if (driver.id() != ioapic.id) return error.IdMismatch;
        try drivers.appendBounded(driver);
    }

    log.debug("ioapic drivers: {any}", .{drivers.items});
    const d = drivers.items[0];
    d.write(.id, 2 << 24);
    log.debug("id: {b}", .{d.id()});
}
