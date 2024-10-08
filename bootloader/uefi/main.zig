const std = @import("std");
const uefi = std.os.uefi;
const serial = @import("serial.zig");
const logger = @import("logger.zig");
const Globals = @import("globals.zig");
const BootInfo = @import("bootinfo.zig").BootInfo;
const Config = @import("config.zig");
const Video = @import("video.zig");
const FileSystem = @import("fs.zig");
const Mmap = @import("mmap.zig");
const KernelLoader = @import("kernel_loader.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub fn main() uefi.Status {
    logger.init(serial.Port.COM1);
    Globals.init();
    FileSystem.init() catch {
        std.log.err("Failed to initialize filesystem subsystem", .{});
        return uefi.Status.Aborted;
    };
    Video.init();

    const config = FileSystem.loadFile("/SYS/KERNEL.CON") catch {
        std.log.err("Failed to load config file", .{});
        return uefi.Status.Aborted;
    };
    std.log.debug(
        \\Got config:
        \\{s}"
    , .{config.getContents()});

    const bootloader_config = Config.parseConfig(config.getContents()) catch {
        std.log.err("Failed to parse config", .{});
        return uefi.Status.Aborted;
    };
    std.log.info(
        \\Parsed config file
        \\Kernel file: {s}
        \\Video resolution: {d} x {d}"
    , .{
        bootloader_config.kernel,
        bootloader_config.video.width,
        bootloader_config.video.height,
    });

    const video_info: Video.VideoInfo = Video.getPreferredResolution() catch blk: {
        std.log.warn("Could not resolve display preferred resolution, falling back on config", .{});
        break :blk .{ .device_handle = null, .resolution = bootloader_config.video };
    };

    std.log.info("Using resolution {d}x{d}", .{
        video_info.resolution.width,
        video_info.resolution.height,
    });

    Video.getFramebuffer(video_info) catch {
        std.log.err("Could not set video mode", .{});
        return uefi.Status.Aborted;
    };
    Video.fillRect(255, 8, 4) catch {
        std.log.err("FillRect failed", .{});
        return uefi.Status.Aborted;
    };

    const kernel = FileSystem.loadFile(bootloader_config.kernel) catch {
        std.log.err("Could not load kernel file", .{});
        return uefi.Status.Aborted;
    };
    _ = &kernel;

    const kernel_info = KernelLoader.loadExecutable(kernel.getContents()) catch {
        std.log.err("Could not load kernel executable", .{});
        return uefi.Status.Aborted;
    };
    _ = &kernel_info;

    // Mmap.getMemMap() catch {
    //     std.log.err("Failed to get memory map", .{});
    //     return uefi.Status.Aborted;
    // };

    const conin = Globals.sys_table.con_in.?;
    const input_events = [_]uefi.Event{
        conin.wait_for_key,
    };

    var index: usize = undefined;
    while (Globals.boot_services.waitForEvent(input_events.len, &input_events, &index) == uefi.Status.Success) {
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
