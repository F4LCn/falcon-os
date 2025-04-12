const std = @import("std");

const log = std.log.scoped(.spin_lock);

const INVALID_CPU_ID = std.math.maxInt(u32);
pub const SpinLock = struct {
    const Self = @This();
    cpu_id: u32,
    locked: bool,
    lock_count: u32,
    saved_int_state: bool,

    pub fn create() Self {
        return .{
            .cpu_id = INVALID_CPU_ID,
            .locked = false,
            .lock_count = 0,
            .saved_int_state = false,
        };
    }

    pub fn lock(self: Self) void {
        _ = self;
        log.debug("Locking", .{});
    }

    pub fn unlock(self: Self) void {
        _ = self;
        log.debug("Unlocking", .{});
    }
};
