const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");
const logger = @import("logger.zig");

pub fn main() uefi.Status {
    const sys_table = uefi.system_table;
    const conout = sys_table.con_out.?;
    const boot_services = sys_table.boot_services.?;

    const serial_writer = serial.SerialWriter.init(serial.Port.COM1).writer();
    const log = logger.Logger(serial.SerialWriter.Writer, serial.SerialWriter.SerialError).init(serial_writer);
    const a: u32 = 123;
    log.dbg("This is a debug message with arg {d}\n", .{a}) catch unreachable;
    log.inf("Info message\n", .{}) catch unreachable;
    log.wrn("Warning message\n", .{}) catch unreachable;
    log.err("Error message\n", .{}) catch unreachable;

    const conin = sys_table.con_in.?;
    const input_events = [_]uefi.Event{
        conin.wait_for_key,
    };

    var index: usize = undefined;
    while (boot_services.waitForEvent(input_events.len, &input_events, &index) == uefi.Status.Success) {
        if (index == 0) {
            var input_key: uefi.protocol.SimpleTextInputEx.Key.Input = undefined;
            if (conin.readKeyStroke(&input_key) == uefi.Status.Success) {
                if (input_key.unicode_char == @as(u16, 'Q')) {
                    return uefi.Status.Success;
                }
                const slice: [*:0]const u16 = &[_:0]u16{input_key.unicode_char};
                _ = conout.outputString(slice);
            }
        }
    }

    return uefi.Status.Timeout;
}
