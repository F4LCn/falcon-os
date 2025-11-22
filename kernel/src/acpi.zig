const std = @import("std");
const BootInfo = @import("flcn").bootinfo.BootInfo;
const Memory = @import("memory.zig");
const arch = @import("arch");
const flcn = @import("flcn");
const acpi_types = flcn.acpi;
const acpi_events = flcn.acpi_events;

extern var bootinfo: BootInfo;
const log = std.log.scoped(.acpi);

pub const AcpiTableIterationContext = struct {
    ptr: *const anyopaque,
    cb: *const fn (*const anyopaque, args: anytype) void,

    pub fn notify(self: *const AcpiTableIterationContext, args: anytype) void {
        self.cb(self.ptr, args);
    }
};

const AcpiTable = struct {
    phys_addr: arch.memory.PAddrSize,
    virt_addr: arch.memory.VAddrSize,
    is_valid: bool,
    header: acpi_types.DescriptionHeader,

    pub fn init(header: *const acpi_types.DescriptionHeader) AcpiTable {
        const paddr = Memory.kernel_vmem.virtToPhys(@bitCast(@intFromPtr(header)));
        const is_valid = validateChecksum(header);
        return .{
            .phys_addr = paddr,
            .virt_addr = @intFromPtr(header),
            .is_valid = is_valid,
            .header = header.*,
        };
    }
    pub fn initFromPhys(paddr: arch.memory.PAddr) AcpiTable {
        const table_addr = Memory.kernel_vmem.physToVirt(paddr).toAddr();
        const header: *const acpi_types.DescriptionHeader = @ptrFromInt(table_addr);
        return .init(header);
    }
};

const AcpiTableMap = std.EnumMap(acpi_types.TableSignatures, AcpiTable);
var acpi_tables: AcpiTableMap = undefined;

pub fn init() !void {
    const rsdp_paddr = bootinfo.acpi_ptr;
    const rsdp_addr = Memory.kernel_vmem.physToVirt(rsdp_paddr).toAddr();
    log.info("found ACPI root table at 0x{x}", .{rsdp_addr});
    acpi_tables = .init(.{});
    try initFromRsdt(rsdp_addr);
    log.info("Initialized tables {any}", .{acpi_tables});
}

pub fn iterateTable(sig: acpi_types.TableSignatures, ctx: AcpiTableIterationContext) !void {
    const table_opt = acpi_tables.getPtrConst(sig);
    if (table_opt) |table| {
        switch (sig) {
            .apic => {
                if (!table.is_valid) return error.BadChecksum;
                const madt: *const acpi_types.AcpiMadt = @ptrFromInt(table.virt_addr);
                ctx.notify(acpi_events.MadtParsingEvent{ .local_apic_addr = madt.lapic_addr });
                if (madt.flags.pcat_compat) ctx.notify(acpi_events.MadtParsingEvent{ .pic_compatibility = {} });
                const table_end: u64 = table.virt_addr + table.header.len;
                var interruptControllerHeader: *const acpi_types.AcpiMadt.InterruptControllerHeader = @ptrFromInt(table.virt_addr + @sizeOf(acpi_types.AcpiMadt));

                while (@intFromPtr(interruptControllerHeader) < table_end) : (interruptControllerHeader = @ptrFromInt(@intFromPtr(interruptControllerHeader) + interruptControllerHeader.length)) {
                    log.debug("found madt interrupt controller with type {t}", .{interruptControllerHeader.typ});
                    switch (interruptControllerHeader.typ) {
                        .processorLocalApic => {
                            const processorLocalApic: *const acpi_types.AcpiMadt.ProcessorLocalApic = @ptrCast(interruptControllerHeader);
                            log.debug("local apic {any}", .{processorLocalApic});
                            ctx.notify(acpi_events.MadtParsingEvent{
                                .apic = .{
                                    .id = processorLocalApic.processor_uid,
                                    .apic_id = processorLocalApic.apic_id,
                                    .enabled = processorLocalApic.flags.enabled,
                                    .online_capable = processorLocalApic.flags.online_capable,
                                },
                            });
                        },
                        .ioApic => {
                            const ioapic: *const acpi_types.AcpiMadt.IoApic = @ptrCast(interruptControllerHeader);
                            log.err("ioapic {any}", .{ioapic});
                        },
                        .interruptSourceOverride => {
                            const intSourceOverride: *const acpi_types.AcpiMadt.InterruptSourceOverride = @ptrCast(interruptControllerHeader);
                            log.err("interrupt source override {any}", .{intSourceOverride});
                        },
                        else => {
                            log.warn("Unhandled interrupt controller type {t}", .{interruptControllerHeader.typ});
                        },
                        _ => unreachable,
                    }
                }

                return;
            },
            else => unreachable,
        }
    }
    return error.TableNotFound;
}

fn initFromRsdt(rsdp_addr: u64) !void {
    const rsdp: *align(1) const acpi_types.AcpiRsdp = @ptrFromInt(rsdp_addr);
    const rsdt_paddr = if (rsdp.rev == 2) rsdp.xsdt_addr else rsdp.rsdt_addr;
    const rsdt_addr = Memory.kernel_vmem.physToVirt(rsdt_paddr).toAddr();
    const header: *const acpi_types.DescriptionHeader = @ptrFromInt(rsdt_addr);
    const header_sig = std.mem.bytesAsValue(u32, &header.sig).*;
    if (header_sig != @intFromEnum(acpi_types.TableSignatures.rsdt) and header_sig != @intFromEnum(acpi_types.TableSignatures.xsdt)) {
        return error.BadSignature;
    }
    if (!validateChecksum(header)) return error.BadChecksum;
    try findRXsdtEntries(header);
}

fn findRXsdtEntries(header: *const acpi_types.DescriptionHeader) !void {
    const header_sig = std.mem.bytesAsValue(u32, &header.sig).*;
    if (header_sig == @intFromEnum(acpi_types.TableSignatures.xsdt)) {
        acpi_tables.put(.xsdt, .init(header));
        const entries_ptr: [*]align(1) const u64 = @ptrFromInt(@intFromPtr(header) + @sizeOf(acpi_types.DescriptionHeader));
        log.debug("header @ {*} -> entries @ {*}", .{ header, entries_ptr });
        const entries = entries_ptr[0 .. (header.len - @sizeOf(acpi_types.DescriptionHeader)) / @sizeOf(u64)];
        for (entries) |entry| {
            log.debug("found entry @ 0x{x}", .{entry});
            parseTable(u64, entry);
        }
    } else if (header_sig == @intFromEnum(acpi_types.TableSignatures.rsdt)) {
        acpi_tables.put(.rsdt, .init(header));
        const entries_ptr: [*]align(1) const u32 = @ptrFromInt(@intFromPtr(header) + @sizeOf(acpi_types.DescriptionHeader));
        const entries = entries_ptr[0 .. (header.len - @sizeOf(acpi_types.DescriptionHeader)) / @sizeOf(u32)];
        for (entries) |entry| {
            log.debug("found entry @ 0x{x}", .{entry});
        }
    } else {
        return error.BadSignature;
    }
}

fn parseTable(comptime TAddr: type, addr: TAddr) void {
    const acpi_table: AcpiTable = .initFromPhys(addr);
    log.debug("parsed table with signature {s}", .{acpi_table.header.sig});
    acpi_tables.put(.fromSignature(&acpi_table.header.sig), acpi_table);
}

fn validateChecksum(header: *const acpi_types.DescriptionHeader) bool {
    const table = @as([*]const u8, @ptrCast(header))[0..header.len];
    var checksum: u8 = 0;
    for (table) |c| {
        checksum +%= c;
    }
    if (checksum != 0) return false;
    return true;
}
