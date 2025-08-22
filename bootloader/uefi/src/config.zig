const std = @import("std");
const BootloaderError = @import("errors.zig").BootloaderError;
const VideoResolution = @import("video.zig").VideoResolution;

const log = std.log.scoped(.config);

pub const BootloaderConfig = struct {
    kernel: []const u8 = "",
    video: VideoResolution = .{ .width = 640, .height = 480 },
};

pub fn parseConfig(config: []const u8) BootloaderError!BootloaderConfig {
    var parsed: BootloaderConfig = .{};
    // NOTE: every config line is of format: "KEY=VALUE\n"
    var line_tokenizer = std.mem.tokenizeScalar(u8, config, '\n');
    while (line_tokenizer.next()) |line| {
        var kv_split_iterator = std.mem.splitScalar(u8, line, '=');
        if (kv_split_iterator.next()) |key| {
            const value = kv_split_iterator.rest();
            if (std.mem.eql(u8, key, "KERNEL")) {
                parsed.kernel = value;
            } else if (std.mem.eql(u8, key, "VIDEO")) {
                // NOTE: video resolution should be of format WxH (eg. 600x480)
                var vid_resolution_split_iterator = std.mem.splitScalar(u8, value, 'x');
                if (vid_resolution_split_iterator.next()) |w| {
                    const h = vid_resolution_split_iterator.rest();
                    const width = std.fmt.parseInt(u16, w, 10) catch {
                        log.err("Error while parsing width ({s}) (should be a valid u16)", .{w});
                        return BootloaderError.ConfigParseError;
                    };
                    const height = std.fmt.parseInt(u16, h, 10) catch {
                        log.err("Error while parsing height ({s}) (should be a valid u16)", .{h});
                        return BootloaderError.ConfigParseError;
                    };
                    parsed.video = .{ .width = width, .height = height };
                }
            }
        }
    }
    return parsed;
}
