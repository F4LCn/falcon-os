const std = @import("std");
const serial = @import("serial.zig");

var serial_out: ?serial.SerialWriter = null;

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var s = serial_out  orelse return;
    var w = &s.writer;
    const scope_prefix = switch (scope) {
        std.log.default_log_scope => "",
        else => "(" ++ @tagName(scope) ++ ") ",
    };
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    w.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn writer() !*std.Io.Writer {
    var s = serial_out orelse return error.LoggerNotInit;
    return &s.writer;
}

pub fn init(comptime port: serial.Port) void {
    serial_out = serial.SerialWriter.init(port);
}
