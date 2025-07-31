const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "backend",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("httpz", httpz_dep.module("httpz"));

    const dotenv_dep = b.dependency("dotenv", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("dotenv", dotenv_dep.module("dotenv"));

    const zul_dep = b.dependency("zul", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("zul", zul_dep.module("zul"));

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    exe.root_module.addImport("zqlite", zqlite.module("zqlite"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
