const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .abi = .none,
        .ofmt = .elf,
        .os_tag = .freestanding,
    });
    const default_target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kernel_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .omit_frame_pointer = true,
        .pic = true,
        .code_model = .kernel,
        .sanitize_thread = false,
    });
    const constants = registerConstants(b, target.result.cpu.arch);
    kernel_module.addOptions("constants", constants);

    const kernel_exe = b.addExecutable(.{
        .name = "kernel64.elf",
        .root_module = kernel_module,
        .use_llvm = true,
        .use_lld = true,
    });

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
}

fn registerConstants(b: *std.Build, arch: std.Target.Cpu.Arch) *std.Build.Step.Options {
    const max_cpu_option = b.option(u64, "max_cpu", "Max platform CPUs") orelse 0;

    const constants = b.addOptions();
    constants.addOption(u64, "max_cpu", max_cpu_option);
    constants.addOption(comptime_int, "max_interrupt_vectors", 256);
    constants.addOption(std.Target.Cpu.Arch, "arch", arch);
    constants.addOption(comptime_int, "heap_size", 1 * 1024 * 1024);
    constants.addOption(comptime_int, "permanent_heap_size", 4 * 1024 * 1024);
    switch (arch) {
        .x86_64 => constants.addOption(comptime_int, "arch_page_size", 1 << 12),
        else => constants.addOption(comptime_int, "arch_page_size", 0),
    }

    return constants;
}
