const std = @import("std");
const uefi = std.os.uefi;
const Globals = @import("globals.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const Constants = @import("constants.zig");
const MemHelper = @import("mem_helper.zig");

const log = std.log.scoped(.file_system);

var boot_services: *uefi.tables.BootServices = undefined;
var _file_system: *uefi.protocol.SimpleFileSystem = undefined;
var _root: *uefi.protocol.File = undefined;

pub const FileBuffer = struct {
    buffer: [*]align(Constants.arch_page_size) u8,
    size: usize,
    len: usize,

    pub fn getContents(self: *const FileBuffer) []u8 {
        return self.buffer[0..self.len];
    }

    pub fn deinit(self: *FileBuffer) !void {
        return MemHelper.freePages(self.buffer, self.size);
    }
};

pub fn init() BootloaderError!void {
    var status: uefi.Status = undefined;
    boot_services = Globals.boot_services;
    status = boot_services._locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @as(*?*const anyopaque, @ptrCast(&_file_system)));
    switch (status) {
        .success => log.debug("Located the file system protocol", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }
    status = _file_system._open_volume(_file_system, @ptrCast(&_root));
    switch (status) {
        .success => log.debug("Successfully opened the root volume", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }
}

// TODO: put all args into args
pub fn loadFile(args: struct { path: []const u8, type: MemHelper.MemoryType = .RECLAIMABLE }) BootloaderError!FileBuffer {
    var status: uefi.Status = undefined;

    var file_handle: *uefi.protocol.File = undefined;
    var utf16_buffer = [_:0]u16{0} ** 265;
    const len = std.unicode.utf8ToUtf16Le(&utf16_buffer, args.path[0..]) catch {
        return BootloaderError.InvalidPathError;
    };
    std.mem.replaceScalar(u16, &utf16_buffer, '/', '\\');
    log.debug("Converted str: {s} -> {any} ({d})", .{ args.path, utf16_buffer, len });
    status = _root._open(_root, @ptrCast(&file_handle), &utf16_buffer, uefi.protocol.File.OpenMode.read, .{});
    defer _ = _root._close(file_handle);
    switch (status) {
        .success => log.debug("Opened file {s}", .{args.path}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    var file_info_size: usize = 0;
    var file_info: *uefi.protocol.File.Info.File = undefined;
    status = file_handle._get_info(file_handle, &uefi.protocol.File.Info.File.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .buffer_too_small => log.debug("Need to allocate {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    status = boot_services._allocatePool(.loader_data, file_info_size, @as(*[*]align(8) u8, @ptrCast(@alignCast(&file_info))));
    defer _ = boot_services._freePool(@as([*]align(8) u8, @ptrCast(@alignCast(file_info))));
    switch (status) {
        .success => log.debug("Allocated {d} bytes for file info", .{file_info_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    status = file_handle._get_info(file_handle, &uefi.protocol.File.Info.File.guid, &file_info_size, @as([*]u8, @ptrCast(file_info)));
    switch (status) {
        .success => log.debug("Got file info: file size is {d} bytes", .{file_info.file_size}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    var file_buffer_size = std.mem.alignForward(usize, @intCast(file_info.file_size), Constants.arch_page_size);
    const pages_to_allocate = @divExact(file_buffer_size, Constants.arch_page_size);
    const contents = MemHelper.allocatePages(pages_to_allocate, args.type) catch {
        return BootloaderError.FileLoadError;
    };

    status = file_handle._read(file_handle, &file_buffer_size, contents);
    switch (status) {
        .success => log.debug("Read file contents", .{}),
        else => {
            log.err("Expected Success but got {s} instead", .{@tagName(status)});
            return BootloaderError.FileLoadError;
        },
    }

    return .{ .buffer = contents, .size = pages_to_allocate * Constants.arch_page_size, .len = file_info.file_size };
}
