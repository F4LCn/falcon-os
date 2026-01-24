const std = @import("std");
const constants = @import("constants.zig");
const memory = @import("memory.zig");
const smp = @import("smp.zig");
const options = @import("options");
const interrupts = @import("interrupts.zig");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.ioapic);

const IoApicDriver = struct {
    const Id = packed struct {
        _reserved0: u24,
        id: u4,
        _reserved1: u4,
    };

    const Version = packed struct {
        version: u8,
        _reserved0: u8,
        max_redirection_entry: u8,
        _reserved1: u8,
    };

    const RedirectionEntry = packed struct {
        const DeliveryMode = enum(u3) {
            fixed = 0b000,
            lowest_priority = 0b001,
            smi = 0b010,
            nmi = 0b100,
            init = 0b101,
            ext_int = 0b111,
        };
        const Polarity = enum(u1) {
            active_high = 0,
            active_low = 1,
        };
        const TriggerMode = enum(u1) {
            level_triggered = 1,
            edge_triggered = 0,
        };

        vector: u8,
        delivery_mode: DeliveryMode,
        destination_mode: u1 = 0,
        delivery_status: u1 = 0,
        polarity: Polarity = .active_high,
        remote_irr: u1 = 0,
        trigger_mode: TriggerMode = .edge_triggered,
        masked: bool,
        _reserved0: u39 = 0,
        destination: u8,

        pub fn lower(self: RedirectionEntry) u32 {
            const int: u64 = @bitCast(self);
            return @truncate(int);
        }

        pub fn higher(self: RedirectionEntry) u32 {
            const int: u64 = @bitCast(self);
            return @truncate(int >> 32);
        }
    };

    const register_select_offset = 0x00;
    const window_offset = 0x10;
    const Register = enum(u8) { id = 0x0, version = 0x1, arb_id = 0x2, redirection_table = 0x10, _ };

    _base_phys_addr: u32,
    base_addr: memory.VAddr,
    register_select: *volatile u32,
    window: *volatile u32,
    gsi_base: u32,
    redirection_count: u8,

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
        const register_select: *volatile u32 = @ptrFromInt(ioapic_base.toAddr() + register_select_offset);
        const window: *volatile u32 = @ptrFromInt(ioapic_base.toAddr() + window_offset);
        const reg_offset = @intFromEnum(Register.version);
        register_select.* = reg_offset;
        const ver_reg: Version = @bitCast(window.*);
        const redirection_count = ver_reg.max_redirection_entry + 1;
        return .{
            ._base_phys_addr = base_addr,
            .base_addr = ioapic_base,
            .register_select = register_select,
            .window = window,
            .gsi_base = gsi_base,
            .redirection_count = redirection_count,
        };
    }

    pub fn initRedirectionTable(self: IoApicDriver, int_src_overrides: []smp.IntSourceOverride) void {
        if(options.safety) {
            if(!cpu.perCpu(.is_bsp)) @panic("attempted to init ioapic from non-bsp");
        }
        for (0..self.redirection_count) |i| {
            // FIXME: system to mark interrupts as "allocated"
            const irq_id = @as(u8, @truncate(i));
            var redirection_entry = self.readRedirectionTableEntry(irq_id);
            redirection_entry.masked = true;
            self.writeRedirectionTableEntry(irq_id, redirection_entry);
        }

        for (int_src_overrides) |int_src_override| {
            if (int_src_override.gsi < self.gsi_base or int_src_override.gsi >= self.gsi_base + self.redirection_count) continue;
            const irq_id: u8 = @truncate(int_src_override.gsi - self.gsi_base);
            var redirection_entry = self.readRedirectionTableEntry(irq_id);
            const new_vector = interrupts.system_interrupt_count + irq_id;
            const new_polarity: RedirectionEntry.Polarity = switch (int_src_override.polarity) {
                .bus_conforming, .active_high => .active_high,
                .active_low => .active_low,
            };
            const new_trigger_mode: RedirectionEntry.TriggerMode = switch (int_src_override.trigger_mode) {
                .bus_conforming, .edge_triggered => .edge_triggered,
                .level_triggered => .level_triggered,
            };
            redirection_entry.polarity = new_polarity;
            redirection_entry.trigger_mode = new_trigger_mode;
            redirection_entry.vector = new_vector;
            redirection_entry.masked = false;
            self.writeRedirectionTableEntry(irq_id, redirection_entry);
        }
    }

    pub fn id(self: IoApicDriver) u32 {
        const id_reg: Id = @bitCast(self.read(.id));
        return id_reg.id;
    }

    pub fn version(self: IoApicDriver) Version {
        const version_reg: Version = @bitCast(self.read(.version));
        return version_reg;
    }

    fn read(self: IoApicDriver, reg: Register) u32 {
        const reg_offset = @intFromEnum(reg);
        self.register_select.* = reg_offset;
        // log.debug("reading {t}@{*}: {x}", .{ reg, self.window, self.window.* });
        return self.window.*;
    }

    fn write(self: IoApicDriver, reg: Register, val: u32) void {
        const reg_offset = @intFromEnum(reg);
        self.register_select.* = reg_offset;

        self.window.* = val;
        // log.debug("wrote {t}@{*}: {x}", .{ reg, self.window, self.window.* });
    }

    fn readRedirectionTableEntry(self: IoApicDriver, idx: u8) RedirectionEntry {
        const redtbl_reg_lo = @intFromEnum(Register.redirection_table) + 2 * idx;
        const redtbl_reg_hi = @intFromEnum(Register.redirection_table) + 2 * idx + 1;

        const redtbl_hi = self.read(@enumFromInt(redtbl_reg_hi));
        const redtbl_lo = self.read(@enumFromInt(redtbl_reg_lo));
        const redtbl: u64 = (@as(u64, @intCast(redtbl_hi)) << 32) | redtbl_lo;
        return @bitCast(redtbl);
    }

    fn writeRedirectionTableEntry(self: IoApicDriver, idx: u8, entry: RedirectionEntry) void {
        const redtbl_reg_lo = @intFromEnum(Register.redirection_table) + 2 * idx;
        const redtbl_reg_hi = @intFromEnum(Register.redirection_table) + 2 * idx + 1;

        const redtbl_lo = entry.lower();
        const redtbl_hi = entry.higher();
        self.write(@enumFromInt(redtbl_reg_lo), redtbl_lo);
        self.write(@enumFromInt(redtbl_reg_hi), redtbl_hi);
    }
};

var drivers_buf: [options.max_cpu]IoApicDriver = .{undefined} ** options.max_cpu;
var drivers: std.ArrayList(IoApicDriver) = .initBuffer(&drivers_buf);
pub fn init(ioapics: []smp.IoApic, int_src_overrides: []smp.IntSourceOverride, page_map: *memory.PageMapManager) !void {
    for (ioapics) |ioapic| {
        const driver: IoApicDriver = try .init(ioapic.address, ioapic.gsi_base, page_map);
        driver.initRedirectionTable(int_src_overrides);
        log.debug("ioapic driver {d}, version={any}, max redir={d}", .{ driver.id(), driver.version(), driver.redirection_count });
        if (driver.id() != ioapic.id) return error.IdMismatch;
        try drivers.appendBounded(driver);
    }

    log.info("ioapic subsystem initialized", .{});
}
