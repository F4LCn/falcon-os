const std = @import("std");
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

pub const Timestamp = std.Io.Timestamp;
pub const Duration = std.Io.Duration;

pub const TickCount = u64;
pub const TickFreq = u64;

pub const TickSource = struct {
    _read: *const fn () anyerror!TickCount,
    _freq: *const fn () anyerror!TickFreq,
    priority: u8, // NOTE: the higher the better

    pub fn read(self: TickSource) !TickCount {
        try self._read();
    }

    pub fn freq(self: TickSource) !TickFreq {
        try self._freq();
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
    _program_interrupt: *const fn (deadline: Duration) anyerror!void,
    priority: u8, // NOTE: the higher the better

    pub fn programInterrupt(self: TickNotifier, deadline: Duration) !void {
        try self._program_interrupt(deadline);
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
    return std.math.order(a.deadline, b.deadline);
}

var tick_sources_buffer: [16]TickSource = .{undefined} ** 16;
var tick_notifiers_buffer: [16]TickNotifier = .{undefined} ** 16;
var time_manager: Self = undefined;

pub fn getClock(clock_type: ClockType) Timestamp {
    const c = time_manager.clocks.get(clock_type);
    return .{ .nanoseconds = c.now };
}

const Self = @This();
allocator: std.mem.Allocator,

tick_sources: std.ArrayList(TickSource) = .initBuffer(&tick_sources_buffer),
tick_notifiers: std.ArrayList(TickNotifier) = .initBuffer(&tick_notifiers_buffer),

active_tick_source: TickSource,
active_tick_notifier: TickNotifier,

last_ticks: TickCount,

clocks: std.EnumArray(ClockType, Clock),

// timer_cache: add a timer cache/slab allocator here

// TODO: one of these per-cpu please
timers: std.PriorityQueue(Timer, void, timerLt) = .empty,

pub fn init(allocator: std.mem.Allocator) void {
    time_manager = .{
        .allocator = allocator,
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
}

fn updateClocks(self: *Self, elapsed: Duration) void {
    for (&self.clocks.values) |*clock| {
        clock.update(elapsed);
    }
}

fn serviceTimers(self: *Self) !void {
    const cutoff_time = getClock(.realtime);
    var timers_buffer: [128]Timer = .{undefined} ** 128;
    const timers = std.ArrayList(Timer).initBuffer(&timers_buffer);
    while (self.timers.peek()) |t| {
        if (t.deadline > cutoff_time) return;
        var timer = self.timers.pop().?;

        // WARN: danger zone
        timer.notify();

        if (timer.period) |_| {
            timer.reArm();
            try timers.appendBounded(timer);
        }
    }

    self.timers.pushSlice(self.allocator, timers.items);
}

pub fn updateTime(self: *Self) !void {
    const ticks_now = try self.active_tick_source.read();
    defer self.last_ticks = ticks_now;
    // 1/ count elasped ticks
    const ticks_elapsed = ticks_now - self.last_ticks;
    // 2/ convert to nanoseconds
    const freq = try self.active_tick_source.freq();
    // TODO: make the freq in units of ns (or any units that would make conversion painless)
    const elasped_duration: Duration = .{ .nanoseconds = ticks_elapsed / freq };
    // 3/ update clocks
    self.updateClocks(elasped_duration);
    // 4.1/ walk the prio queue and service elasped timers
    // 4.2/ rearm periodic timers
    self.serviceTimers();
}
