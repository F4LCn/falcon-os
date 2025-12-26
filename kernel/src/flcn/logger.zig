const std = @import("std");
const serial = @import("serial.zig");

pub fn Logger(comptime SerialWriter: type, comptime Port: type) type {
    return struct {
        serial_out: ?SerialWriter = null,

        pub fn init(comptime port: Port) @This() {
            return .{ .serial_out = SerialWriter.init(port) };
        }
    };
}

pub fn logFn(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    var s = logger.serial_out orelse return;
    var w = &s.writer;
    const scope_prefix = switch (scope) {
        std.log.default_log_scope => "",
        else => "(" ++ @tagName(scope) ++ ") ",
    };
    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;
    w.print(prefix ++ format ++ "\n", args) catch return;
}

var logger: Logger(serial.SerialWriter, serial.Port) = undefined;
pub fn init(comptime port: serial.Port) void {
    logger = Logger(serial.SerialWriter, serial.Port).init(port);
}
