// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const text = b.dependency("fluxion_text", .{ .target = target, .optimize = optimize });
    const hash = b.dependency("fluxion_hash", .{ .target = target, .optimize = optimize });
    const data = b.dependency("fluxion_data", .{ .target = target, .optimize = optimize });
    const jobs = b.dependency("fluxion_jobs", .{ .target = target, .optimize = optimize });

    // The importable module. Consumers do:
    //   const vfs = @import("fluxion_vfs");
    const mod = b.addModule("fluxion_vfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_text", .module = text.module("fluxion_text") },
            .{ .name = "fluxion_hash", .module = hash.module("fluxion_hash") },
            .{ .name = "fluxion_data", .module = data.module("fluxion_data") },
            .{ .name = "fluxion_jobs", .module = jobs.module("fluxion_jobs") },
        },
    });

    // zig build test
    const tests = b.addTest(.{
        .name = "fluxion-vfs-tests",
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the library test suite");
    test_step.dependOn(&run_tests.step);

    // The examples, each a program of its own.
    const examples = [_]struct { name: []const u8, file: []const u8, step: []const u8, help: []const u8 }{
        .{
            .name = "fluxion-vfs-demo",
            .file = "examples/demo.zig",
            .step = "example",
            .help = "Build and run the demo program",
        },
        .{
            .name = "fluxion-pack",
            .file = "examples/pack.zig",
            .step = "pack",
            .help = "Build and run the pack tool",
        },
    };

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(example.file),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "fluxion_vfs", .module = mod }},
        });
        const exe = b.addExecutable(.{ .name = example.name, .root_module = example_mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step(example.step, example.help).dependOn(&run.step);

        const example_tests = b.addTest(.{
            .name = b.fmt("{s}-tests", .{example.name}),
            .root_module = example_mod,
        });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);
    }

    // zig build docs -> zig-out/docs
    const docs_lib = b.addLibrary(.{ .name = "fluxion-vfs", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);
}
