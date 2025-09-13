const std = @import("std");
const serial = @import("serial.zig");

var serial_out: ?serial.SerialWriter = null;

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var serial_writer = serial_out orelse return;
    var writer = &serial_writer.writer;
    const scope_prefix = switch (scope) {
        std.log.default_log_scope => "",
        else => "(" ++ @tagName(scope) ++ ") ",
    };
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    writer.print(prefix ++ format ++ "\n", args) catch return;
}

pub fn init(comptime port: serial.Port) void {
    serial_out = serial.SerialWriter.init(port);
}
