const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get z_ens_normalize dependency
    const ens_normalize = b.dependency("z_ens_normalize", .{
        .target = target,
        .optimize = optimize,
    });

    // Create GraphQL library module for use by test files
    const graphql_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/graphql/graphql.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Combined indexer executable (both V1 and V2 in one process)
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

    // V1-only indexer executable (separate process)
    const indexer_v1_exe = b.addExecutable(.{
        .name = "ensv2-indexer-v1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_v1_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    indexer_v1_exe.linkLibC();
    indexer_v1_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(indexer_v1_exe);

    // V2-only indexer executable (separate process)
    const indexer_v2_exe = b.addExecutable(.{
        .name = "ensv2-indexer-v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_v2_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    indexer_v2_exe.linkLibC();
    indexer_v2_exe.linkSystemLibrary("sqlite3");
    b.installArtifact(indexer_v2_exe);

    // Generate GraphQL introspection from schema.graphql
    const generate_schema = b.addSystemCommand(&[_][]const u8{
        "python3",
        "tools/generate_introspection.py",
        "schema.graphql",
        "src/api/introspection.json",
    });
    generate_schema.setCwd(b.path("."));

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
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("sqlite3");

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Create shared lib module for test imports (single module to avoid conflicts)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    integration_tests.linkLibC();
    integration_tests.linkSystemLibrary("sqlite3");

    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.setCwd(b.path("."));
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // GraphQL parser tests
    const graphql_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphql/graphql_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphql", .module = graphql_lib_mod },
            },
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
            .root_source_file = b.path("tests/graphql/graphql_features_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphql", .module = graphql_lib_mod },
            },
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

    // lib/graphql/json_writer inline tests (self-contained within lib/graphql)
    const json_writer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib/graphql/json_writer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_json_writer_tests = b.addRunArtifact(json_writer_tests);
    const json_writer_test_step = b.step("test-json-writer", "Run JSON writer helper tests");
    json_writer_test_step.dependOn(&run_json_writer_tests.step);

    // API module inline tests (rooted at api_main so cross-directory imports resolve).
    // Covers src/api/common.zig, src/api/loaders.zig, and any other `test` blocks
    // transitively reachable from the API entry point.
    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    api_tests.linkLibC();
    api_tests.linkSystemLibrary("sqlite3");
    const run_api_tests = b.addRunArtifact(api_tests);
    run_api_tests.setCwd(b.path("."));
    const api_test_step = b.step("test-api", "Run api-module inline tests");
    api_test_step.dependOn(&run_api_tests.step);


    // Event filtering tests
    const events_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/events_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    events_tests.linkLibC();
    events_tests.linkSystemLibrary("sqlite3");

    const run_events_tests = b.addRunArtifact(events_tests);
    run_events_tests.setCwd(b.path("."));
    const events_test_step = b.step("test-events", "Run event filtering tests");
    events_test_step.dependOn(&run_events_tests.step);

    // Apollo Client compatibility tests
    const apollo_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphql/apollo_compatibility_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphql", .module = graphql_lib_mod },
            },
        }),
    });

    const run_apollo_tests = b.addRunArtifact(apollo_tests);
    const apollo_test_step = b.step("test-apollo", "Run Apollo Client compatibility tests");
    apollo_test_step.dependOn(&run_apollo_tests.step);

    // Also add to the main graphql test step
    graphql_test_step.dependOn(&run_apollo_tests.step);

    // GraphQL variables tests (parsing and resolution)
    const variables_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphql/variables_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphql", .module = graphql_lib_mod },
            },
        }),
    });

    const run_variables_tests = b.addRunArtifact(variables_tests);
    const variables_test_step = b.step("test-variables", "Run GraphQL variables tests");
    variables_test_step.dependOn(&run_variables_tests.step);

    // Also add to the main graphql test step
    graphql_test_step.dependOn(&run_variables_tests.step);

    // Address validation tests (for contractAddress filter in events query)
    const address_validation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api/address_validation_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "address", .module = b.createModule(.{
                    .root_source_file = b.path("src/types/address.zig"),
                    .target = target,
                    .optimize = optimize,
                }) },
            },
        }),
    });

    const run_address_validation_tests = b.addRunArtifact(address_validation_tests);
    const address_validation_test_step = b.step("test-address", "Run address validation tests");
    address_validation_test_step.dependOn(&run_address_validation_tests.step);

    // Also add to the main filter test step
    filter_test_step.dependOn(&run_address_validation_tests.step);

    const helpers_mod = b.createModule(.{
        .root_source_file = b.path("tests/helpers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
        },
    });

    // Storage tests - names
    const storage_names_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/names_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_names_tests.linkLibC();
    storage_names_tests.linkSystemLibrary("sqlite3");

    const run_storage_names_tests = b.addRunArtifact(storage_names_tests);
    run_storage_names_tests.setCwd(b.path("."));

    // Storage tests - resolvers
    const storage_resolvers_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/resolvers_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_resolvers_tests.linkLibC();
    storage_resolvers_tests.linkSystemLibrary("sqlite3");

    const run_storage_resolvers_tests = b.addRunArtifact(storage_resolvers_tests);
    run_storage_resolvers_tests.setCwd(b.path("."));

    // Storage tests - roles
    const storage_roles_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/roles_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_roles_tests.linkLibC();
    storage_roles_tests.linkSystemLibrary("sqlite3");

    const run_storage_roles_tests = b.addRunArtifact(storage_roles_tests);
    run_storage_roles_tests.setCwd(b.path("."));

    // Storage tests - webhooks
    const storage_webhooks_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/webhooks_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_webhooks_tests.linkLibC();
    storage_webhooks_tests.linkSystemLibrary("sqlite3");

    const run_storage_webhooks_tests = b.addRunArtifact(storage_webhooks_tests);
    run_storage_webhooks_tests.setCwd(b.path("."));

    // Storage test step
    const storage_test_step = b.step("test-storage", "Run storage module tests");
    storage_test_step.dependOn(&run_storage_names_tests.step);
    storage_test_step.dependOn(&run_storage_resolvers_tests.step);
    storage_test_step.dependOn(&run_storage_roles_tests.step);
    storage_test_step.dependOn(&run_storage_webhooks_tests.step);

    // Make the default test command run all tests
    test_step.dependOn(&run_filter_tests.step);
    test_step.dependOn(&run_json_writer_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_events_tests.step);
    test_step.dependOn(&run_apollo_tests.step);
    test_step.dependOn(&run_variables_tests.step);
    test_step.dependOn(&run_address_validation_tests.step);
    test_step.dependOn(&run_storage_names_tests.step);
    test_step.dependOn(&run_storage_resolvers_tests.step);
    test_step.dependOn(&run_storage_roles_tests.step);
    test_step.dependOn(&run_storage_webhooks_tests.step);
}
