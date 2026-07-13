const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimple_mod = b.addModule("zimple", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zimple",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = zimple_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }
    const bench_step = b.step("benchmark", "Run data structure benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Lisp interpreter benchmark
    const lisp_exe = b.addExecutable(.{
        .name = "lisp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lisp/harness.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_lisp = b.addRunArtifact(lisp_exe);
    const lisp_step = b.step("lisp", "Run Lisp interpreter benchmark");
    lisp_step.dependOn(&run_lisp.step);

    // Particle simulation benchmark
    const particle_exe = b.addExecutable(.{
        .name = "particle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/particle_sim.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_particle = b.addRunArtifact(particle_exe);
    const particle_step = b.step("particle", "Run particle simulation benchmark");
    particle_step.dependOn(&run_particle.step);

    // Zig vs Zimple comparison harness
    const compare_exe = b.addExecutable(.{
        .name = "compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare/harness.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    // TODO demo app
    const todo_exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/todo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    b.installArtifact(todo_exe);

    const run_compare = b.addRunArtifact(compare_exe);
    const compare_step = b.step("compare", "Run Zig vs Zimple LOC comparison");
    compare_step.dependOn(&run_compare.step);

    // HAMT performance comparison
    const bench_hamt_exe = b.addExecutable(.{
        .name = "bench-hamt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_hamt.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_bench_hamt = b.addRunArtifact(bench_hamt_exe);
    const bench_hamt_step = b.step("bench-hamt", "Run HAMT AMAC benchmark");
    bench_hamt_step.dependOn(&run_bench_hamt.step);

    // Parallel reduce comparison
    const bench_par_exe = b.addExecutable(.{
        .name = "bench-par",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench_par.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_bench_par = b.addRunArtifact(bench_par_exe);
    const bench_par_step = b.step("bench-par", "Run Parallel Adaptive Reduce benchmark");
    bench_par_step.dependOn(&run_bench_par.step);

    // Performance comparison
    const perf_exe = b.addExecutable(.{
        .name = "compare-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/compare/perf.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zimple", .module = zimple_mod },
            },
        }),
    });
    const run_perf = b.addRunArtifact(perf_exe);
    const perf_step = b.step("compare-perf", "Run Zig vs Zimple performance comparison");
    perf_step.dependOn(&run_perf.step);
}
