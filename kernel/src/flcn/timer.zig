const std = @import("std");
const irq = @import("irq.zig");
// NOTE: design notes for time keeping subsystem
// * arch independent tick source "interface" offers a read() -> u64 function to read the underlying timer chip counter
// * time keeping can register different tick source implementations each of which has a precision factor (sort of minimal/typical period ?) that determines priority
// * always read from the highest priority timer available
// * maybe another tick notifier "interface", offers a function to program a timer interrupt
// * time keeping keeps a clock (ticks) + different "clock sources" as offsets to the clock ticks
// * for ex: maybe we have a time of day clock; offset set on start up by reading the time of day from the RTC
// * for ex: a monotonic clock; offset 0 from clock
// * time keeping registers a timer interrupt handler
// * on interrupt read tick source and update clock ticks
// * processes can request ticks for different clock source ?
// * timer interrupt programmed on-demand by looking at all things that need to be serviced on that interrupt
// * and taking the soonest expiration, maybe that way the kernel would get out of the way of userspace if there is no need to
// * schedule/service timers

// NOTE: design notes for timers
// * time keeping subsystem has an API to create timers
// * timers have a callback + a deadline (delay before first tick) + period (delay before ticks) ?

const log = std.log.scoped(.timer);

pub const Timestamp = std.Io.Timestamp;
pub const Duration = std.Io.Duration;

pub const TickCount = u64;
pub const TickFreq = u64;

pub const TickSource = struct {
    _read: *const fn () anyerror!TickCount,
    _freq: *const fn () anyerror!TickFreq,
    max_counter: u64,
    priority: u8, // NOTE: the higher the better

    pub fn read(self: TickSource) !TickCount {
        return try self._read();
    }

    pub fn freq(self: TickSource) !TickFreq {
        return try self._freq();
    }

    pub fn toNanoseconds(self: TickSource) !Duration {
        // TODO:: impl this
        _ = self;
        return .{
            .nanoseconds = 0,
        };
    }
};

pub const TickNotifier = struct {
    _program_interrupt: *const fn (deadline: Duration) anyerror!irq.IrqHandle,
    priority: u8, // NOTE: the higher the better

    pub fn programInterrupt(self: TickNotifier, deadline: Duration) !irq.IrqHandle {
        return try self._program_interrupt(deadline);
    }
};

pub const ClockOffset = i96;
pub const ClockType = enum { monotonic, realtime };
pub const Clock = struct {
    now: Timestamp,

    pub fn init(offset: ClockOffset) Clock {
        return .{
            .now = .fromNanoseconds(offset),
        };
    }

    pub fn update(self: *Clock, nanoseconds_delta: Duration) void {
        self.now.nanoseconds += nanoseconds_delta.nanoseconds;
    }
};

pub const Timer = struct {
    deadline: Timestamp,
    period: ?Duration = null,
    context: ?*anyopaque = null,
    callback: *const fn (?*anyopaque) void,

    pub fn oneShot(callback: *const fn (?*anyopaque) void, duration: Duration) Timer {
        return .{
            .callback = callback,
            .deadline = getClock(.monotonic).addDuration(duration),
        };
    }

    pub fn notify(self: Timer) void {
        self.callback(self.context);
    }

    pub fn reArm(self: *Timer) void {
        if (self.period) |p| {
            self.deadline = getClock(.realtime).addDuration(p);
        } else unreachable;
    }
};
fn timerLt(_: void, a: Timer, b: Timer) std.math.Order {
    return std.math.order(a.deadline.nanoseconds, b.deadline.nanoseconds);
}

var tick_sources_buffer: [16]TickSource = .{undefined} ** 16;
var tick_notifiers_buffer: [16]TickNotifier = .{undefined} ** 16;
var time_manager: Self = undefined;

pub fn getClock(clock_type: ClockType) Timestamp {
    const c = time_manager.clocks.get(clock_type);
    return .{ .nanoseconds = c.now.nanoseconds };
}

const Self = @This();
allocator: std.mem.Allocator,

tick_sources: std.ArrayList(TickSource) = .initBuffer(&tick_sources_buffer),
tick_notifiers: std.ArrayList(TickNotifier) = .initBuffer(&tick_notifiers_buffer),

active_tick_source: TickSource,
active_tick_notifier: TickNotifier,
active_tick_notifier_handle: ?irq.IrqHandle,

last_ticks: TickCount = 0,

clocks: std.EnumArray(ClockType, Clock),

// timer_cache: add a timer cache/slab allocator here

// TODO: one of these per-cpu please
timers: std.PriorityQueue(Timer, void, timerLt) = .empty,

pub fn init(allocator: std.mem.Allocator) void {
    time_manager = .{
        .allocator = allocator,
        .clocks = .initDefault(.{ .now = .fromNanoseconds(0) }, .{}),
        .active_tick_source = undefined,
        .active_tick_notifier = undefined,
        .active_tick_notifier_handle = null,
    };
}

pub fn registerTickSource(self: *Self, tick_source: TickSource) !void {
    try self.tick_sources.appendBounded(tick_source);
    self.reElectTickSource();
}

pub fn registerTickNotifier(self: *Self, tick_notifier: TickNotifier) !void {
    try self.tick_notifiers.appendBounded(tick_notifier);
    self.reElectTickNotifier();
}

fn reElectTickSource(self: *Self) void {
    std.debug.assert(self.tick_sources.items.len > 0);
    var best: TickSource = self.tick_sources.items[0];
    for (self.tick_sources.items[1..]) |ts| {
        if (ts.priority > best.priority) best = ts;
    }
    self.active_tick_source = best;
    self.last_ticks = self.active_tick_source.read() catch unreachable;
}

fn reElectTickNotifier(self: *Self) void {
    std.debug.assert(self.tick_notifiers.items.len > 0);
    var best: TickNotifier = self.tick_notifiers.items[0];
    for (self.tick_notifiers.items[1..]) |ts| {
        if (ts.priority > best.priority) best = ts;
    }
    self.active_tick_notifier = best;
}

pub fn createTimer(self: *Self, timer: Timer) !void {
    try self.timers.push(self.allocator, timer);
    // TODO: remove this !!!!
    try self.updateTime();
}

fn updateClocks(self: *Self, elapsed: Duration) void {
    for (&self.clocks.values) |*clock| {
        clock.update(elapsed);
    }
}

fn serviceTimers(self: *Self) !void {
    const cutoff_time = getClock(.monotonic);
    var timers_buffer: [128]Timer = .{undefined} ** 128;
    var timers = std.ArrayList(Timer).initBuffer(&timers_buffer);
    while (self.timers.peek()) |t| {
        if (t.deadline.nanoseconds > cutoff_time.nanoseconds) return;
        var timer = self.timers.pop().?;

        // WARN: danger zone
        timer.notify();

        if (timer.period) |_| {
            timer.reArm();
            try timers.appendBounded(timer);
        }
    }

    try self.timers.pushSlice(self.allocator, timers.items);
}

pub fn updateTime(self: *Self) !void {
    if (self.active_tick_notifier_handle) |handle| try irq.mask(handle);

    const ticks_now = try self.active_tick_source.read();
    defer self.last_ticks = ticks_now;
    // 1/ count elapsed ticks
    const ticks_elapsed = if (self.last_ticks > ticks_now) self.last_ticks - ticks_now else self.active_tick_source.max_counter - (ticks_now - self.last_ticks);

    // 2/ convert to nanoseconds
    const freq = try self.active_tick_source.freq();
    // TODO: make the freq in units of ns (or any units that would make conversion painless)
    const elapsed_duration: Duration = .{ .nanoseconds = ticks_elapsed * 1_000_000_000 / freq };
    // 3/ update clocks
    self.updateClocks(elapsed_duration);
    // 4.1/ walk the prio queue and service elapsed timers
    // 4.2/ rearm periodic timers
    try self.serviceTimers();
    if (self.timers.peek()) |timer| {
        const now = getClock(.monotonic);
        const duration = now.durationTo(timer.deadline);
        self.active_tick_notifier_handle = try self.active_tick_notifier.programInterrupt(duration);
        try irq.unmask(self.active_tick_notifier_handle.?);
    }
}

pub fn waitDuration(self: *Self, duration: Duration) !void {
    const freq = try self.active_tick_source.freq();
    var ticks = @divTrunc(duration.toNanoseconds() * freq, 1_000_000_000);
    var last_count = try self.active_tick_source.read();
    while (ticks > 0) {
        const current_count = try self.active_tick_source.read();
        if (current_count < last_count) {
            ticks -= last_count - current_count;
        } else {
            ticks -= self.active_tick_source.max_counter - (current_count - last_count);
        }
        last_count = current_count;
    }
}

// -------------------

pub fn timerHandler(_: *const irq.Context, _: ?*anyopaque) void {
    time_manager.updateTime() catch @panic("asdfadf");
}

pub fn wait(duration: Duration) void {
    time_manager.waitDuration(duration) catch unreachable;
}

pub fn _registerTickSource(tick_source: TickSource) void {
    time_manager.registerTickSource(tick_source) catch unreachable;
}

pub fn _registerTickNotifier(tick_notifier: TickNotifier) void {
    time_manager.registerTickNotifier(tick_notifier) catch unreachable;
}

pub fn _createTimer(timer: Timer) void {
    time_manager.createTimer(timer) catch unreachable;
}
