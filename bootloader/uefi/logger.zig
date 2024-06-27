const std = @import("std");

pub fn Logger(comptime WriterType: type, comptime WriterError: type) type {
    return struct {
        _writer: WriterType,

        const Self = @This();

        pub fn init(writer: WriterType) Self {
            return .{ ._writer = writer };
        }

        pub fn dbg(self: Self, comptime fmt: []const u8, args: anytype) WriterError!void {
            const format = "DBG: " ++ fmt;
            return self._writer.print(format, args);
        }
        pub fn inf(self: Self, comptime fmt: []const u8, args: anytype) WriterError!void {
            const format = "INF: " ++ fmt;
            return self._writer.print(format, args);
        }
        pub fn wrn(self: Self, comptime fmt: []const u8, args: anytype) WriterError!void {
            const format = "WRN: " ++ fmt;
            return self._writer.print(format, args);
        }
        pub fn err(self: Self, comptime fmt: []const u8, args: anytype) WriterError!void {
            const format = "ERR: " ++ fmt;
            return self._writer.print(format, args);
        }
    };
}
