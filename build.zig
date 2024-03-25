const std = @import("std");

const Dependency = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const ExeConfig = struct {
    version: ?std.SemanticVersion = null, // The version of the executable
    name: []const u8, // @param[in] name: The name for the generated executable
    build_cmd: []const u8, // The build step name ('zig build <cmd>')
    build_description: []const u8, // The description for the build step ('zig build -l')
    run_cmd: []const u8, // The run step name ('zig build <cmd>')
    run_description: []const u8, //  The description for the run step ('zig build -l')
    root_path: []const u8, // The zig file containing main()
};

const BuildOpts = struct {
    optimize: std.builtin.OptimizeMode,
    target: ?std.Build.ResolvedTarget = null,
    dependencies: ?[]Dependency = null,
};

pub fn build(b: *std.Build) !void {
    // Default build target, unless overridden with '-Dtarget=<>'
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // // Default to ReleaseSafe, but allow the user to specify Debug or ReleaseFast builds
    // var optimize: std.builtin.Mode = .ReleaseSafe;
    // if (b.option(bool, "debug", "Build Debug mode") != null) {
    //     optimize = .Debug;
    // } else if (b.option(bool, "fast", "Build ReleaseFast mode") != null) {
    //     optimize = .ReleaseFast;
    // }

    ///////////////////////////////////////////////////////////////////////////
    // Dependencies from build.zig.zon
    // ------------------------------------------------------------------------
    // Zigdown
    const zigdown = b.dependency("zigdown", .{ .optimize = optimize, .target = target });
    const zigdown_dep = Dependency{ .name = "zigdown", .module = zigdown.module("zigdown") };

    // Zig-Clap
    const clap = b.dependency("zig_clap", .{ .optimize = optimize, .target = target });
    const clap_dep = Dependency{ .name = "clap", .module = clap.module("clap") };

    var dep_array = [_]Dependency{ zigdown_dep, clap_dep };
    const deps: []Dependency = &dep_array;

    const exe_opts = BuildOpts{
        .target = target,
        .optimize = optimize,
        .dependencies = deps,
    };

    // Compile the main executable
    const exe_config = ExeConfig{
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .name = "slidey",
        .build_cmd = "slidey",
        .build_description = "Build the Slidey executable",
        .run_cmd = "run",
        .run_description = "Run the slidey executable (use `-- <args>` to supply arguments)",
        .root_path = "src/main.zig",
    };
    addExecutable(b, exe_config, exe_opts);

    // Add unit tests

    const test_opts = BuildOpts{ .optimize = optimize, .dependencies = deps };
    _ = test_opts;
    // addTest(b, "test-all", "Run all unit tests", "src/test.zig", test_opts);

    const test_config = ExeConfig{
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .name = "test-stdin",
        .build_cmd = "testin",
        .build_description = "Build the stdin test executable",
        .run_cmd = "run-testin",
        .run_description = "Run the stdin test xecutable (use `-- <args>` to supply arguments)",
        .root_path = "src/test.zig",
    };
    addExecutable(b, test_config, exe_opts);
}

/// Add an executable (build & run) step using the given file
///
/// @param[inout] b: Mutable pointer to the Build object
/// @param[in] optimize: Build optimization settings
fn addExecutable(b: *std.Build, config: ExeConfig, opts: BuildOpts) void {
    // Compile the executable
    const exe = b.addExecutable(.{
        .name = config.name,
        .root_source_file = .{ .path = config.root_path },
        .version = config.version,
        .optimize = opts.optimize,
        .target = opts.target orelse b.host,
    });

    // Add the executable to the default 'zig build' command
    b.installArtifact(exe);

    // Add dependencies
    if (opts.dependencies) |deps| {
        for (deps) |dep| {
            exe.root_module.addImport(dep.name, dep.module);
        }
    }

    // Add a build-only step
    const build_step = b.step(config.build_cmd, config.build_description);
    build_step.dependOn(&exe.step);

    // Configure how the main executable should be run
    const run_exe = b.addRunArtifact(exe);
    const exe_install = b.addInstallArtifact(exe, .{});
    run_exe.step.dependOn(&exe_install.step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const step = b.step(config.run_cmd, config.run_description);
    step.dependOn(&run_exe.step);
}

/// Add a unit test step using the given file
///
/// @param[inout] b: Mutable pointer to the Build object
/// @param[in] cmd: The build step name ('zig build cmd')
/// @param[in] description: The description for 'zig build -l'
/// @param[in] path: The zig file to test
/// @param[in] opts: Build target and optimization settings, along with any dependencies needed
fn addTest(b: *std.Build, cmd: []const u8, description: []const u8, path: []const u8, opts: BuildOpts) void {
    const test_exe = b.addTest(.{
        .root_source_file = .{ .path = path },
        .optimize = opts.optimize,
        .target = opts.target,
    });

    if (opts.dependencies) |deps| {
        for (deps) |dep| {
            test_exe.root_module.addImport(dep.name, dep.module);
        }
    }

    const run_step = b.addRunArtifact(test_exe);
    run_step.has_side_effects = true; // Force the test to always be run on command
    const step = b.step(cmd, description);
    step.dependOn(&run_step.step);
}
