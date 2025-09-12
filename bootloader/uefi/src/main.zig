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
const Constants = @import("constants.zig");
const AddressSpace = @import("address_space.zig");
const BootloaderError = @import("errors.zig").BootloaderError;
const MemHelper = @import("mem_helper.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .info,
};

pub fn main() uefi.Status {
    logger.init(serial.Port.COM1);
    Globals.init();
    FileSystem.init() catch {
        std.log.err("Failed to initialize filesystem subsystem", .{});
        return uefi.Status.aborted;
    };
    Video.init();

    const bootinfo_page = MemHelper.allocatePages(1, .BOOTINFO) catch {
        std.log.err("Could not allocate a page for bootinfo struct", .{});
        return uefi.Status.aborted;
    };
    const bootinfo: *align(Constants.arch_page_size) BootInfo = @ptrCast(bootinfo_page);
    bootinfo.* = .{
        .bootloader_type = .UEFI,
        .mmap = .{
            .ptr = 0xABABABAB,
            .len = 12345,
        },
    };

    const config = FileSystem.loadFile(.{ .path = "/SYS/KERNEL.CON", .type = .BOOTINFO }) catch {
        std.log.err("Failed to load config file", .{});
        return uefi.Status.aborted;
    };
    std.log.debug(
        \\Got config:
        \\{s}"
    , .{config.getContents()});

    const bootloader_config = Config.parseConfig(config.getContents()) catch {
        std.log.err("Failed to parse config", .{});
        return uefi.Status.aborted;
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

    Video.getFramebuffer(video_info, bootinfo) catch {
        std.log.err("Could not set video mode", .{});
        return uefi.Status.aborted;
    };
    Video.fillRect(255, 8, 4) catch {
        std.log.err("FillRect failed", .{});
        return uefi.Status.aborted;
    };

    std.log.debug("Bootinfo struct: {any}", .{bootinfo});

    var kernel = FileSystem.loadFile(.{ .path = bootloader_config.kernel }) catch {
        std.log.err("Could not load kernel file", .{});
        return uefi.Status.aborted;
    };

    const kernel_info = KernelLoader.loadExecutable(kernel.getContents()) catch {
        std.log.err("Could not load kernel executable", .{});
        return uefi.Status.aborted;
    };

    std.log.debug("Kernel info: ", .{});
    std.log.debug("  entrypoint: 0x{X}", .{kernel_info.entrypoint});
    std.log.debug("  entry count: {d}", .{kernel_info.segment_count});
    for (0..kernel_info.segment_count) |idx| {
        const mapping = kernel_info.segment_mappings[idx];
        const mapping_vaddr = switch (mapping.vaddr) {
            .vaddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        const mapping_paddr = switch (mapping.paddr) {
            .paddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        std.log.info("  mapping[{d}]: p=0x{X} v=0x{X} l={d}", .{ idx, @as(u64, mapping_paddr), @as(u64, mapping_vaddr), mapping.len });
    }

    var addr_space = AddressSpace.create() catch {
        std.log.err("Could not create address space", .{});
        return uefi.Status.aborted;
    };

    const fb_ptr = bootinfo.fb_ptr;
    const fb_size = (@as(u64, bootinfo.fb_height)) * (@as(u64, bootinfo.fb_scanline_bytes));
    mapKernelSpace(&addr_space, &kernel_info, @intFromPtr(bootinfo), fb_ptr, fb_size, @intFromPtr(config.buffer)) catch {
        std.log.err("Could not map kernel address space", .{});
        return uefi.Status.aborted;
    };

    // addr_space.print();

    std.log.debug("bootinfo page: {X}", .{bootinfo_page[0..200]});
    kernel.deinit() catch {
        std.log.err("Could not free kernel buffer", .{});
        return uefi.Status.aborted;
    };

    const mmap_entries: [*]BootInfo.MmapEntry = @ptrCast(&bootinfo.mmap);
    const map_key = Mmap.getMemMap(bootinfo) catch |e| {
        std.log.err("Failed to get memory map. Error: {}", .{e});
        std.log.err("mmap: ", .{});
        for (mmap_entries[0..5], 0..) |entry, i| {
            std.log.err("[{d}] entry: Start=0x{X} Size=0x{X} Typ={}", .{ i, entry.getPtr(), entry.getLen(), entry.getType() });
        }
        return uefi.Status.aborted;
    };
    for (mmap_entries[0..30], 0..) |entry, i| {
        std.log.debug("[{d}] entry: Start=0x{X} Size=0x{X} Typ={}", .{ i, entry.getPtr(), entry.getLen(), entry.getType() });
    }

    const _marker: u64 = 32;
    std.log.info(
        \\ preparing to exit boot services
        \\ page map -> 0x{X}
        \\ kernel_entry -> 0x{X}
        \\ current addr -> 0x{X}
    , .{ addr_space.root, kernel_info.entrypoint, @intFromPtr(&_marker) });

    // TODO: exit boot services
    const status = Globals.boot_services._exitBootServices(uefi.handle, map_key);
    switch (status) {
        .success => {
            std.log.info("Exited boot services. Handling execution to kernel ...", .{});
        },
        else => {
            std.log.err("Could not exit boot services, bad map key", .{});
            return uefi.Status.aborted;
        },
    }

    // WARN: Don't use boot_services after this line

    // NOTE: We currently randomly page fault on setting the new page map to CR3
    // if UEFI chooses to load the bootloader too high in memory (around 3G)
    // this means that we need to keep about 4Gb identity mapped and pray
    // FIXME: This needs to be written to a trampoline page we are SURE stays (identity) mapped
    asm volatile (
        \\ mov %cr4, %rax
        \\ or $0x620, %rax
        \\ mov %rax, %cr4
        \\ mov %[kernel_entry], %rax
        \\ mov %[page_map], %cr3  // <- this causes the problem
        \\ jmp *%rax
        \\ _catch:
        \\ jmp _catch
        :
        : [page_map] "r" (addr_space.root),
          [kernel_entry] "r" (kernel_info.entrypoint),
        : .{ .rax = true }
    );

    return uefi.Status.timeout;
}

fn mapKernelSpace(
    addr_space: *AddressSpace,
    kernel_info: *const KernelLoader.KernelInfo,
    bootinfo_ptr: u64,
    fb_ptr: u64,
    fb_size: u64,
    env_ptr: u64,
) BootloaderError!void {
    const log = std.log.scoped(.KernelSpaceMapper);
    log.info("Mapping kernel space", .{});
    // core stack
    var core_stack_vaddr: u64 = -%@as(u64, Constants.arch_page_size);
    for (0..Constants.max_cpu) |i| {
        const core_stack_ptr = try MemHelper.allocatePages(1, .ReservedMemoryType);
        log.debug("Mapping core[{d}] stack: 0x{X} -> [0x{X} -> 0x{X}]", .{
            i,
            @intFromPtr(core_stack_ptr),
            core_stack_vaddr,
            core_stack_vaddr +% Constants.arch_page_size,
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(core_stack_vaddr) },
            .{ .paddr = @intFromPtr(core_stack_ptr) },
            AddressSpace.DefaultMmapFlags,
        );
        core_stack_vaddr -%= Constants.arch_page_size;
    }
    // kernel
    var kernel_end: u64 = 0;
    for (0..kernel_info.segment_count) |idx| {
        const mapping = &kernel_info.segment_mappings[idx];
        log.debug("kernel segment: {any}", .{mapping});
        var mapping_vaddr = switch (mapping.vaddr) {
            .vaddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        var mapping_paddr = switch (mapping.paddr) {
            .paddr => |x| @as(u64, @bitCast(x)),
            else => unreachable,
        };
        log.debug("Mapping kernel segment 0x{X} -> 0x{X} {X}", .{
            @as(u64, @bitCast(mapping_paddr)),
            @as(u64, @bitCast(mapping_vaddr)),
            mapping.len,
        });
        const num_pages = ((mapping.len + Constants.arch_page_size - 1) / Constants.arch_page_size);
        for (0..num_pages) |p| {
            defer mapping_paddr += Constants.arch_page_size;
            defer mapping_vaddr += Constants.arch_page_size;
            log.debug("\t kernel segment[{d}] 0x{X} -> 0x{X}", .{
                p,
                @as(u64, @bitCast(mapping_paddr)),
                @as(u64, @bitCast(mapping_vaddr)),
            });
            try addr_space.mmap(
                .{ .vaddr = @bitCast(mapping_vaddr) },
                .{ .paddr = mapping_paddr },
                AddressSpace.DefaultMmapFlags,
            );
            kernel_end = mapping_vaddr;
        }
    }
    kernel_end += Constants.arch_page_size;

    const quickmap_start = kernel_end + 2 * Constants.arch_page_size;
    log.info("Kernel end found @ 0x{X}", .{kernel_end});
    const quickmap_pages = Constants.max_cpu;
    var quickmap_page = quickmap_start;
    const placeholder_addr: u64 = 0xDEADBEEF;
    for (0..quickmap_pages) |p| {
        defer quickmap_page += Constants.arch_page_size;
        log.info("\t Quickmap page[{d}] 0x{X} -> 0x{X}", .{
            p,
            @as(u64, @bitCast(placeholder_addr)),
            @as(u64, @bitCast(quickmap_page)),
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(quickmap_page) },
            .{ .paddr = placeholder_addr },
            AddressSpace.DefaultMmapFlags,
        );
    }

    const quickmap_pt_entry_length = std.mem.alignForward(u64, Constants.max_cpu * @sizeOf(AddressSpace.PageMapping.Entry), Constants.arch_page_size);
    const quickmap_pt_entry_pages = @divFloor(quickmap_pt_entry_length + Constants.arch_page_size - 1, Constants.arch_page_size);
    const quickmap_pt_entry_start = -%(@as(u64, Constants.arch_page_size) * Constants.max_cpu) - quickmap_pt_entry_length - 2 * Constants.arch_page_size;
    var quickmap_pt_entry_page = quickmap_pt_entry_start;
    quickmap_page = quickmap_start;
    for (0..quickmap_pt_entry_pages) |p| {
        defer quickmap_pt_entry_page += Constants.arch_page_size;
        defer quickmap_page += Constants.arch_page_size;

        const quickmap_page_addr: AddressSpace.Pml4VirtualAddress = @bitCast(quickmap_page);
        const pte_addr = try addr_space.getPageTableEntry(quickmap_page_addr, AddressSpace.DefaultMmapFlags);
        log.info("Quickmap PTE 0x{X} paddr=0x{X}", .{ @intFromPtr(pte_addr), pte_addr.getAddr() });
        const pte_page_addr = std.mem.alignBackward(u64, @intFromPtr(pte_addr), Constants.arch_page_size);
        log.info("\t Quickmap pte page[{d}] 0x{X} -> 0x{X}", .{
            p,
            @as(u64, @bitCast(pte_page_addr)),
            @as(u64, @bitCast(quickmap_pt_entry_page)),
        });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(quickmap_pt_entry_page) },
            .{ .paddr = pte_page_addr },
            AddressSpace.DefaultMmapFlags,
        );
    }

    // bootinfo
    if (kernel_info.bootinfo_addr) |bootinfo_addr| {
        log.info("Mapping bootinfo struct 0x{X} -> 0x{X}", .{ bootinfo_ptr, bootinfo_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(bootinfo_addr) },
            .{ .paddr = bootinfo_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    } else {
        @panic("No bootinfo found");
    }
    // fb
    // TODO: make sure the size is page aligned
    log.debug("Mapping fb", .{});
    if (kernel_info.fb_addr) |fb_addr| {
        log.info("Mapping framebuffer from 0x{X} -> 0x{X} (0x{X})", .{ fb_ptr, fb_addr, fb_size });
        var fb_vaddr = fb_addr;
        var fb_paddr = fb_ptr;
        while (fb_paddr < fb_ptr + fb_size) : ({
            fb_paddr += Constants.arch_page_size;
            fb_vaddr += Constants.arch_page_size;
        }) {
            try addr_space.mmap(
                .{ .vaddr = @bitCast(fb_vaddr) },
                .{ .paddr = fb_paddr },
                AddressSpace.DefaultMmapFlags,
            );
        }
    }
    // env
    if (kernel_info.env_addr) |env_addr| {
        log.debug("Mapping env 0x{X} -> 0x{X}", .{ env_ptr, env_addr });
        try addr_space.mmap(
            .{ .vaddr = @bitCast(env_addr) },
            .{ .paddr = env_ptr },
            AddressSpace.DefaultMmapFlags,
        );
    }
    // Identity mapping
    const identity_map_size: u64 = MemHelper.gb(4);
    log.debug("Mapping identity 512mb 0x{X}", .{identity_map_size});
    var i: u64 = 0;
    while (i < identity_map_size) : (i += Constants.arch_page_size) {
        log.debug("Mapping identity 0x{X}", .{i});
        try addr_space.mmap(
            .{ .vaddr = @bitCast(i) },
            .{ .paddr = @bitCast(i) },
            AddressSpace.DefaultMmapFlags,
        );
    }
}
