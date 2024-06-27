const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");
const logger = @import("logger.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub fn main() uefi.Status {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    logger.init(serial.Port.COM1);

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
            }
        }
    }

    return uefi.Status.Timeout;
}
