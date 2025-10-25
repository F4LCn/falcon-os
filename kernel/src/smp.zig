const std = @import("std");
const acpi = @import("acpi.zig");

const log = std.log.scoped(.smp);

const MadtIterationContext = struct {
    pub fn acpiIterationContext(self: *const MadtIterationContext) acpi.AcpiTableIterationContext2 {
        return .{
            .ptr = self,
            .cb = onCallback,
        };
    }

    fn onCallback(_: *const anyopaque, token: []const u8, args: anytype) void {
        log.debug("OnCallback {s} => {any}", .{ token, args });
    }
};

pub fn init() !void {
    const madtIterationContext = MadtIterationContext{};
    try acpi.iterateTable(.apic, madtIterationContext.acpiIterationContext());
}
