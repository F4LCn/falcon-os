const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .abi = .none,
        .ofmt = .elf,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel_exe = b.addExecutable(.{
        .name = "kernel64.elf",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .sanitize_thread = false,
        .omit_frame_pointer = true,
        .pic = true,
        .code_model = .kernel,
    });

    // switch (optimize) {
    //     .Debug => kernel_exe.root_module.strip = false,
    //     else => kernel_exe.root_module.strip = true,
    // }

    const constants = registerConstants(b, target.result.cpu.arch);
    kernel_exe.root_module.addOptions("constants", constants);

    kernel_exe.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(kernel_exe);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .name = "all_tests",
        .optimize = .Debug,
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
    constants.addOption(std.Target.Cpu.Arch, "arch", arch);
    constants.addOption(comptime_int, "heap_size", 1 * 1024 * 1024);
    constants.addOption(comptime_int, "permanent_heap_size", 4 * 1024 * 1024);
    switch (arch) {
        .x86_64 => constants.addOption(comptime_int, "arch_page_size", 1 << 12),
        else => constants.addOption(comptime_int, "arch_page_size", 0),
    }

    return constants;
}
