const std = @import("std");

pub fn build(b: *std.Build) !void {
    const alloc = b.allocator;
    const build_arch = b.option(std.Target.Cpu.Arch, "arch", "Kernel target architecture") orelse .x86_64;

    const default_target = b.standardTargetOptions(.{});
    const target = b.resolveTargetQuery(.{
        .cpu_arch = build_arch,
        .abi = .none,
        .ofmt = .elf,
        .os_tag = .other,
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        // .omit_frame_pointer = true,
        .red_zone = false,
        .pic = true,
        .code_model = .default,
        .sanitize_thread = false,
        .dwarf_format = .@"64",
    });
    attachConstantsModule(b, kernel_module);
    try attachArchModule(alloc, b, kernel_module);

    const kernel_exe = b.addExecutable(.{
        .name = "kernel64.elf",
        .root_module = kernel_module,
    });

    if (optimize == .Debug or optimize == .ReleaseSafe) {
        kernel_exe.use_llvm = true;
        kernel_exe.compress_debug_sections = .none;
        kernel_exe.use_lld = true;
        kernel_exe.stack_size = 0;
    }

    // TODO: use objcopy for binary stripping

    // switch (optimize) {
    //     .Debug => kernel_exe.root_module.strip = false,
    //     else => kernel_exe.root_module.strip = true,
    // }

    kernel_exe.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel_exe);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .optimize = .Debug,
        .target = default_target,
    });
    const tests = b.addTest(.{
        .name = "all_tests",
        .root_module = tests_module,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const run_lldb = b.addSystemCommand(&.{ "lldb", "--" });
    run_lldb.addArtifactArg(tests);
    const debug_step = b.step("debug", "Debug tests");
    debug_step.dependOn(&run_lldb.step);

    const arch_generator_module = b.createModule(.{
        .target = default_target,
        .optimize = optimize,
        .root_source_file = b.path("tools/generate_arch.zig"),
    });
    const arch_generator = b.addExecutable(.{
        .name = "arch_generator",
        .root_module = arch_generator_module,
    });
    const generate_arch_run = b.addRunArtifact(arch_generator);
    generate_arch_run.addArg(@tagName(build_arch));
    const arch_file = generate_arch_run.addOutputFileArg("arch_file.zig");
    const arch_file_copy = b.addUpdateSourceFiles();
    const dest_file_path = try std.fmt.allocPrint(alloc, "src/arch/{t}/arch.zig", .{build_arch});
    arch_file_copy.addCopyFileToSource(arch_file, dest_file_path);

    const generate_arch_step = b.step("gen-arch", "Generate arch indexes");
    generate_arch_step.dependOn(&arch_file_copy.step);
}

fn attachConstantsModule(b: *std.Build, module: *std.Build.Module) void {
    const max_cpu_option = b.option(u64, "max_cpu", "Max platform CPUs") orelse 0;

    const constants = b.addOptions();
    constants.addOption(u64, "max_cpu", max_cpu_option);
    constants.addOption(bool, "safety", module.optimize.? == .Debug or module.optimize.? == .ReleaseSafe);
    constants.addOption(comptime_int, "num_stack_trace", 5);
    constants.addOption(comptime_int, "heap_size", 1 * 1024 * 1024);
    constants.addOption(comptime_int, "permanent_heap_size", 4 * 1024 * 1024);
    module.addOptions("constants", constants);
}

fn attachArchModule(alloc: std.mem.Allocator, b: *std.Build, module: *std.Build.Module) !void {
    const build_arch = module.resolved_target.?.result.cpu.arch;
    const path = try std.mem.concat(alloc, u8, &.{ "src/arch/", @tagName(build_arch), "/arch.zig" });
    defer alloc.free(path);

    module.addAnonymousImport("arch", .{
        .root_source_file = b.path(path),
    });
}
