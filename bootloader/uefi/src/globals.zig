const std = @import("std");
const uefi = std.os.uefi;

pub var sys_table: *uefi.tables.SystemTable = undefined;
pub var boot_services: *uefi.tables.BootServices = undefined;

pub fn init() void {
    sys_table = uefi.system_table;
    boot_services = sys_table.boot_services.?;
}
