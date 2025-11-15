pub const bootinfo = @import("bootinfo.zig");
pub const list = @import("list.zig");
pub const pmm = @import("pmm.zig");
pub const buddy = @import("buddy.zig");
pub const buddy2 = @import("buddy2.zig");
pub const allocator = @import("allocator.zig");
pub const vmm = @import("vmm.zig");
pub const synchronization = @import("synchronization.zig");
pub const debug = @import("debug.zig");
pub const acpi = @import("acpi.zig");
pub const acpi_events = @import("acpi_events.zig");

test {
    _ = @import("list.zig");
    _ = @import("vmm.zig");
    _ = @import("synchronization.zig");

    _ = @import("pmm.zig");
    _ = @import("vmm.zig");
    _ = @import("buddy.zig");
}
