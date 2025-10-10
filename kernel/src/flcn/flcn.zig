pub const bootinfo = @import("bootinfo.zig");
pub const list = @import("list.zig");
pub const pmm = @import("pmm.zig");
pub const buddy = @import("buddy.zig");
pub const allocator = @import("allocator.zig");
pub const vmm = @import("vmm.zig");
pub const synchronization = @import("synchronization.zig");
pub const debug = @import("debug.zig");

test {
    _ = @import("list.zig");
    _ = @import("vmm.zig");
    _ = @import("synchronization.zig");

    _ = @import("pmm.zig");
    _ = @import("vmm.zig");
    _ = @import("buddy.zig");
}
