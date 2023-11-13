const std = @import("std");

fn build_lotoo(b: *std.build.Builder, target: std.zig.CrossTarget, optimize: std.builtin.OptimizeMode) *std.build.Builder.Step.Compile {
    const zip = b.addModule("zip", .{ .source_file = .{ .path = "src/minizig.zig" } });

    const lotoo = b.addStaticLibrary(.{
        .name = "lotoo",
        .root_source_file = .{ .path = "src/lotoo.zig" },
        .target = target,
        .optimize = optimize,
    });
    lotoo.addIncludePath(.{ .path = "./" });
    lotoo.addIncludePath(.{ .path = "./deps" });
    lotoo.addModule("zip", zip);

    const zip_lib_options = @import("src/minizig.zig").lib_options;
    var flags: [zip_lib_options.len * 2][]const u8 = undefined;
    for (0..zip_lib_options.len) |i| {
        flags[2 * i] = "-D";
        flags[2 * i + 1] = zip_lib_options[i];
    }

    lotoo.addCSourceFile(.{ .file = .{ .path = "deps/miniz.c" }, .flags = &flags });
    lotoo.linkSystemLibrary("c");
    b.installArtifact(lotoo);

    return lotoo;
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lotoo = build_lotoo(b, target, optimize);

    const cli = b.addExecutable(.{
        .name = "cli",
        .target = target,
        .optimize = optimize,
    });
    cli.addCSourceFile(.{ .file = .{ .path = "src/cli.c" }, .flags = &[_][]const u8{"-std=c99"} });
    cli.linkLibrary(lotoo);
    cli.linkSystemLibrary("c");
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cli.step);

    const run_functionnal_tests = b.addRunArtifact(cli);
    run_functionnal_tests.addArg("load ./test/test.zip");
    run_functionnal_tests.addArg("card_next 1");
    run_functionnal_tests.addArg("card_next 1");
    run_functionnal_tests.addArg("card_next 2");
    run_functionnal_tests.addArg("card_next 2");
    run_functionnal_tests.addArg("card_next 3");
    run_functionnal_tests.addArg("card_next 3");
    run_functionnal_tests.addArg("game_start");
    for (0..4) |i| {
        _ = i;
        run_functionnal_tests.addArg("game_next");
    }
    run_functionnal_tests.addArg("game_end");
    run_functionnal_tests.addArg("game_test");
    run_functionnal_tests.addArg("exit");

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_functionnal_tests.step);
}
