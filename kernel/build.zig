const std = @import("std");

pub fn build(b: *std.Build) !void {
    const alloc = b.allocator;
    const build_arch = b.option(std.Target.Cpu.Arch, "arch", "Kernel target architecture") orelse .x86_64;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = build_arch,
        .abi = .none,
        .ofmt = .elf,
        .os_tag = .other,
    });
    const optimize = b.standardOptimizeOption(.{});

    const options_module = createOptionsModule(b, optimize);
    const kernel_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/entrypoint.zig"),
        .red_zone = false,
        .pic = true,
        .code_model = .default,
        .sanitize_thread = false,
        .dwarf_format = .@"64",
        .omit_frame_pointer = false,
    });
    const lib_module = createLibModule(b);
    lib_module.addImport("options", options_module);
    const arch_module = try createArchModule(alloc, b, kernel_module.resolved_target.?.result.cpu.arch);
    arch_module.addImport("flcn", lib_module);
    arch_module.addImport("options", options_module);
    lib_module.addImport("arch", arch_module);
    kernel_module.addImport("options", options_module);
    kernel_module.addImport("flcn", lib_module);
    kernel_module.addImport("arch", arch_module);

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

    const flcn_tests_module = b.createModule(.{
        .root_source_file = b.path("src/flcn/flcn.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    flcn_tests_module.addImport("options", options_module);
    flcn_tests_module.addImport("flcn", lib_module);
    flcn_tests_module.addImport("arch", arch_module);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .optimize = .Debug,
        .target = b.graph.host,
    });
    tests_module.addImport("options", options_module);
    tests_module.addImport("flcn", lib_module);
    tests_module.addImport("arch", arch_module);

    const tests = b.addTest(.{
        .name = "all_tests",
        .root_module = tests_module,
        .use_llvm = true,
    });
    const flcn_tests = b.addTest(.{
        .name = "all_tests",
        .root_module = flcn_tests_module,
        .use_llvm = true,
    });

    const run_tests = b.addRunArtifact(tests);
    const run_flcn_tests = b.addRunArtifact(flcn_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_flcn_tests.step);

    const run_lldb = b.addSystemCommand(&.{ "lldb", "--" });
    run_lldb.addArtifactArg(tests);
    const debug_step = b.step("debug", "Debug tests");
    debug_step.dependOn(&run_lldb.step);

    const arch_generator_module = b.createModule(.{
        .target = b.graph.host,
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

fn createOptionsModule(b: *std.Build, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const options = b.addOptions();
    if (b.available_options_map.get("max_cpu")) |_| {} else {
        const max_cpu_option = b.option(u64, "max_cpu", "Max platform CPUs") orelse 0;
        options.addOption(u64, "max_cpu", max_cpu_option);
    }

    options.addOption(bool, "safety", optimize == .Debug or optimize == .ReleaseSafe);
    options.addOption(comptime_int, "num_stack_trace", 4);
    options.addOption(comptime_int, "heap_size", 1 * 1024 * 1024);
    options.addOption(comptime_int, "permanent_heap_size", 5 * 1024 * 1024);
    return options.createModule();
}

fn createArchModule(alloc: std.mem.Allocator, b: *std.Build, arch: std.Target.Cpu.Arch) !*std.Build.Module {
    const path = try std.mem.concat(alloc, u8, &.{ "src/arch/", @tagName(arch), "/arch.zig" });
    defer alloc.free(path);

    const module = std.Build.Module.create(
        b,
        .{
            .root_source_file = b.path(path),
        },
    );

    try addArchSpecificSteps(arch, alloc, b, module);
    return module;
}

fn addArchSpecificSteps(arch: std.Target.Cpu.Arch, alloc: std.mem.Allocator, b: *std.Build, module: *std.Build.Module) !void {
    switch (arch) {
        .x86_64 => try x86_64SpecificSteps(alloc, b, module),
        else => @panic("Unhandled architecture"),
    }
}

fn x86_64SpecificSteps(_: std.mem.Allocator, b: *std.Build, module: *std.Build.Module) !void {
    const trampoline_path = "src/arch/x86_64/asm/ap_trampoline.asm";
    const trampoline_bin_assemble = b.addSystemCommand(&.{"fasm"});
    trampoline_bin_assemble.addFileArg(b.path(trampoline_path));
    const trampoline_bin = trampoline_bin_assemble.addOutputFileArg("trampoline.bin");

    module.addAnonymousImport("trampoline", .{ .root_source_file = trampoline_bin });
}

fn createLibModule(b: *std.Build) *std.Build.Module {
    const path = "src/flcn/flcn.zig";
    return std.Build.Module.create(
        b,
        .{ .root_source_file = b.path(path) },
    );
}
