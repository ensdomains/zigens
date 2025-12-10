const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get z_ens_normalize dependency
    const ens_normalize = b.dependency("z_ens_normalize", .{
        .target = target,
        .optimize = optimize,
    });

    // Combined indexer executable (both L1 and L2 in one process)
    const indexer_exe = b.addExecutable(.{
        .name = "ensv2-indexer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    indexer_exe.linkLibC();
    indexer_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(indexer_exe);

    // L1-only indexer executable (separate process)
    const indexer_l1_exe = b.addExecutable(.{
        .name = "ensv2-indexer-l1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_l1_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    indexer_l1_exe.linkLibC();
    indexer_l1_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(indexer_l1_exe);

    // L2-only indexer executable (separate process)
    const indexer_l2_exe = b.addExecutable(.{
        .name = "ensv2-indexer-l2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_l2_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    indexer_l2_exe.linkLibC();
    indexer_l2_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(indexer_l2_exe);

    // Generate GraphQL introspection from schema.graphql
    const generate_schema = b.addSystemCommand(&[_][]const u8{
        "python3",
        "tools/generate_introspection.py",
        "schema.graphql",
        "src/api/introspection.json",
    });

    // API server executable (standalone)
    const api_exe = b.addExecutable(.{
        .name = "ensv2-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    api_exe.linkLibC();
    api_exe.linkSystemLibrary("sqlite3");
    api_exe.step.dependOn(&generate_schema.step); // Generate schema before compiling
    b.installArtifact(api_exe);

    // Database reader test executable
    const test_db_reader_exe = b.addExecutable(.{
        .name = "test-db-reader",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_db_reader.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_db_reader_exe.linkLibC();
    test_db_reader_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(test_db_reader_exe);

    // Rainbow backfill tool (standalone)
    const rainbow_backfill_exe = b.addExecutable(.{
        .name = "rainbow-backfill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rainbow_backfill_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rainbow_backfill_exe.linkLibC();
    rainbow_backfill_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(rainbow_backfill_exe);

    // Run commands
    const run_indexer = b.addRunArtifact(indexer_exe);
    run_indexer.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_indexer.addArgs(args);
    }
    const run_indexer_step = b.step("run-indexer", "Run the ENSv2 indexer");
    run_indexer_step.dependOn(&run_indexer.step);

    const run_api = b.addRunArtifact(api_exe);
    run_api.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_api.addArgs(args);
    }
    const run_api_step = b.step("run-api", "Run the ENSv2 API server");
    run_api_step.dependOn(&run_api.step);

    // Default run is indexer
    const run_step = b.step("run", "Run the ENSv2 indexer");
    run_step.dependOn(&run_indexer.step);

    // Tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("sqlite3");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_tests.linkLibC();
    integration_tests.linkSystemLibrary("sqlite3");

    const run_integration_tests = b.addRunArtifact(integration_tests);
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // GraphQL parser tests
    const graphql_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api/graphql_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graphql_tests.linkLibC();
    graphql_tests.linkSystemLibrary("sqlite3");

    const run_graphql_tests = b.addRunArtifact(graphql_tests);
    const graphql_test_step = b.step("test-graphql", "Run GraphQL parser tests");
    graphql_test_step.dependOn(&run_graphql_tests.step);

    // GraphQL feature tests (full coverage)
    const graphql_features_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api/graphql_features_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    graphql_features_tests.linkLibC();
    graphql_features_tests.linkSystemLibrary("sqlite3");

    const run_graphql_features_tests = b.addRunArtifact(graphql_features_tests);
    const graphql_features_test_step = b.step("test-graphql-features", "Run all GraphQL feature tests");
    graphql_features_test_step.dependOn(&run_graphql_features_tests.step);

    // Also add to the main graphql test step
    graphql_test_step.dependOn(&run_graphql_features_tests.step);

    // Filter logic tests
    const filter_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api/filter_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_filter_tests = b.addRunArtifact(filter_tests);
    const filter_test_step = b.step("test-filters", "Run filter logic unit tests");
    filter_test_step.dependOn(&run_filter_tests.step);

    // Make the default test command run all tests
    test_step.dependOn(&run_filter_tests.step);
}
