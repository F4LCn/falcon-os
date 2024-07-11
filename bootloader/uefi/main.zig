const std = @import("std");
const uefi = std.os.uefi;
const utf16 = std.unicode.utf8ToUtf16LeStringLiteral;
const serial = @import("serial.zig");
const logger = @import("logger.zig");

const BootloaderConfig = struct {
    kernel: []const u8 = "",
    video: struct { width: u16 = 640, height: u16 = 480 } = .{},
};

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub fn main() uefi.Status {
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;

    logger.init(serial.Port.COM1);

    getMemMap();
    const config = readConfigFile();
    if (config) |conf| std.log.info("Got config:\n{s}", .{conf});
    const bootloader_config = parseConfig(config);
    if (bootloader_config) |cfg| {
        std.log.info("Parsed config file\nKernel file: {s}\nVideo resolution: {d} x {d}", .{ cfg.kernel, cfg.video.width, cfg.video.height });
    }

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

fn readConfigFile() ?[]const u8 {
    const log = std.log.scoped(.config);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;
    var file_system: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @as(*?*anyopaque, @ptrCast(&file_system)));
    switch (status) {
        .Success => log.debug("Located the file system protocol", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    var root: *uefi.protocol.File = undefined;
    status = file_system.openVolume(&root);
    switch (status) {
        .Success => log.debug("Successfully opened the root volume", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    var config_file: *uefi.protocol.File = undefined;
    status = root.open(&config_file, utf16("\\SYS\\KERNEL.CON"), uefi.protocol.File.efi_file_mode_read, 0);
    switch (status) {
        .Success => log.debug("Opened config file", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    var file_info_size: usize = 0;
    var file_info: *uefi.FileInfo = undefined;
    status = config_file.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .BufferTooSmall => log.debug("Need to allocate {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    status = boot_services.allocatePool(.LoaderData, file_info_size, @as(*[*]align(8) u8, @ptrCast(@alignCast(&file_info))));
    defer _ = boot_services.freePool(@as([*]align(8) u8, @ptrCast(@alignCast(file_info))));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    status = config_file.getInfo(&uefi.FileInfo.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .Success => log.debug("Got file info: file size is {d} bytes", .{file_info.file_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    const page_count = 1;
    var contents: [*]align(4096) u8 = undefined;
    status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, page_count, &contents);
    switch (status) {
        .Success => log.debug("Allocated {d} pages for config file contents", .{page_count}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    var file_buffer_size: usize = page_count * 4096;
    status = config_file.read(&file_buffer_size, contents);
    switch (status) {
        .Success => log.debug("Read file contents", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return null;
        },
    }

    return contents[0..file_info.file_size];
}

fn parseConfig(config: ?[]const u8) ?BootloaderConfig {
    const log = std.log.scoped(.config_parser);
    var parsed: BootloaderConfig = .{};
    if (config) |cfg| {
        // NOTE: every config line is of format: "KEY=VALUE\n"
        var line_tokenizer = std.mem.tokenizeScalar(u8, cfg, '\n');
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
                            return null;
                        };
                        const height = std.fmt.parseInt(u16, h, 10) catch {
                            log.err("Error while parsing height ({s}) (should be a valid u16)", .{h});
                            return null;
                        };
                        parsed.video = .{ .width = width, .height = height };
                    }
                }
            }
        }
    }
    return parsed;
}

fn getMemMap() void {
    const log = std.log.scoped(.memmap);
    const sys_table = uefi.system_table;
    const boot_services = sys_table.boot_services.?;
    var status: uefi.Status = undefined;

    var mmap_size: usize = 0;
    var mmap: ?[*]uefi.tables.MemoryDescriptor = null;
    var mapKey: usize = undefined;
    var descriptor_size: usize = undefined;
    var desscriptor_version: u32 = undefined;
    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .BufferTooSmall => log.debug("Need {d} bytes for memory map buffer", .{mmap_size}),
        else => {
            log.err("Expected BufferTooSmall but got {s} instead", .{@tagName(status)});
            return;
        },
    }

    mmap_size += 2 * descriptor_size;
    status = boot_services.allocatePool(.LoaderData, mmap_size, @ptrCast(&mmap));
    switch (status) {
        .Success => log.debug("Allocated {d} bytes for memory map at {*}", .{ mmap_size, mmap }),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return;
        },
    }

    status = boot_services.getMemoryMap(&mmap_size, mmap, &mapKey, &descriptor_size, &desscriptor_version);
    switch (status) {
        .Success => log.debug("Got memory map", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return;
        },
    }

    log.info("descriptor size: expected={d}, actual={d}", .{ @sizeOf(uefi.tables.MemoryDescriptor), descriptor_size });

    var descriptor: *uefi.tables.MemoryDescriptor = undefined;
    var idx: usize = 0;
    const descriptors_count = mmap_size / descriptor_size;
    while (idx < descriptors_count) : (idx += 1) {
        descriptor = @ptrFromInt(idx * descriptor_size + @intFromPtr(mmap));
        log.info("- Type={s}; {X} -> {X} (size: {X} pages); attr={X}", .{ @tagName(descriptor.type), descriptor.physical_start, descriptor.physical_start + 4096 * descriptor.number_of_pages, descriptor.number_of_pages, @as(u64, @bitCast(descriptor.attribute)) });
    }
}
