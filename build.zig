const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get z_ens_normalize dependency
    const ens_normalize = b.dependency("z_ens_normalize", .{
        .target = target,
        .optimize = optimize,
    });

    // StrobeLabs/eth.zig — Ethereum primitives, ABI codecs, RPC.
    // We're migrating off the hand-written src/indexer/abi.zig (and eventually
    // src/rpc/client.zig) onto this. The old code is kept for fallback while
    // the migration is in progress.
    const eth_dep = b.dependency("eth", .{
        .target = target,
        .optimize = optimize,
    });
    const eth_module = eth_dep.module("eth");

    // PostgreSQL driver dependency (Phase 4). TLS is opt-in via -Dpg-tls: when set,
    // pg.zig links OpenSSL (system libssl/libcrypto) so the driver can negotiate TLS,
    // which managed Postgres (e.g. Neon) requires. Off by default → no openssl linkage,
    // suiting a local/containerized non-TLS Postgres and the SQLite-only builds.
    const pg_tls = b.option(bool, "pg-tls", "Link OpenSSL into the Postgres driver for TLS (required for Neon/managed Postgres)") orelse false;

    // Auxiliary tool binaries (test-db-reader, rainbow-backfill) are not shipped in
    // the Docker image; -Dtools=false drops them from the default install to cut the
    // deployment build by two ReleaseSafe compilations.
    const tools = b.option(bool, "tools", "Install auxiliary tool binaries (test-db-reader, rainbow-backfill)") orelse true;

    // Deployments that run only the split V2 indexer + API (the staging and
    // production compose files) can skip compiling the combined and V1-only
    // indexers entirely: each executable is a separate whole-program optimized
    // compile (minutes each at 2GB+ peak), so -Dexes=v2api roughly halves the
    // Docker image build. Enum-typed, so an invalid value fails the build.
    const ExeSet = enum { all, v2api };
    const exes = b.option(ExeSet, "exes", "Executables to install: all (default) | v2api (ensv2-indexer-v2 + ensv2-api only)") orelse .all;
    const pg_dep = if (pg_tls)
        b.dependency("pg", .{ .target = target, .optimize = optimize, .openssl_lib_name = @as([]const u8, "ssl") })
    else
        b.dependency("pg", .{ .target = target, .optimize = optimize });
    const pg_module = pg_dep.module("pg");

    // Create GraphQL library module for use by test files
    const graphql_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/graphql_lib.zig"),
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
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    indexer_exe.root_module.link_libc = true;
    indexer_exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (exes == .all) b.installArtifact(indexer_exe);

    // V1-only indexer executable (separate process)
    const indexer_v1_exe = b.addExecutable(.{
        .name = "ensv2-indexer-v1",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_v1_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    indexer_v1_exe.root_module.link_libc = true;
    indexer_v1_exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (exes == .all) b.installArtifact(indexer_v1_exe);

    // V2-only indexer executable (separate process)
    const indexer_v2_exe = b.addExecutable(.{
        .name = "ensv2-indexer-v2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_v2_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    indexer_v2_exe.root_module.link_libc = true;
    indexer_v2_exe.root_module.linkSystemLibrary("sqlite3", .{});
    b.installArtifact(indexer_v2_exe);

    // Generate GraphQL introspection from schema.graphql
    const generate_schema = b.addSystemCommand(&[_][]const u8{
        "python3",
        "tools/generate_introspection.py",
        "schema.graphql",
        "src/api/introspection.json",
    });
    generate_schema.setCwd(b.path("."));

    // Transpile the canonical SQLite schema into the Postgres schema so the two
    // never drift; its guard fails the build on any unhandled SQLite construct.
    const generate_pg_schema = b.addSystemCommand(&[_][]const u8{
        "python3",
        "tools/gen_pg_schema.py",
    });
    generate_pg_schema.setCwd(b.path("."));
    b.getInstallStep().dependOn(&generate_pg_schema.step);

    // API server executable (standalone)
    const api_exe = b.addExecutable(.{
        .name = "ensv2-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/api_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    api_exe.root_module.link_libc = true;
    api_exe.root_module.linkSystemLibrary("sqlite3", .{});
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
    test_db_reader_exe.root_module.link_libc = true;
    test_db_reader_exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (tools) b.installArtifact(test_db_reader_exe);

    // Rainbow backfill tool (standalone)
    const rainbow_backfill_exe = b.addExecutable(.{
        .name = "rainbow-backfill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rainbow_backfill_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rainbow_backfill_exe.root_module.link_libc = true;
    rainbow_backfill_exe.root_module.linkSystemLibrary("sqlite3", .{});
    if (tools) b.installArtifact(rainbow_backfill_exe);

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
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    unit_tests.root_module.link_libc = true;
    unit_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.setCwd(b.path("."));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Create shared lib module for test imports (single module to avoid conflicts)
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "eth", .module = eth_module },
            .{ .name = "pg", .module = pg_module },
            .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
        },
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
    integration_tests.root_module.link_libc = true;
    integration_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.setCwd(b.path("."));
    const integration_test_step = b.step("test-integration", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    // Cross-backend: re-run the integration suite against PostgreSQL (TEST_BACKEND=postgres
    // makes testDb open ensv2_test in a fresh per-test schema). Requires a live Postgres.
    const run_integration_pg = b.addRunArtifact(integration_tests);
    run_integration_pg.setCwd(b.path("."));
    run_integration_pg.setEnvironmentVariable("TEST_BACKEND", "postgres");
    const integration_pg_step = b.step("test-integration-pg", "Run integration tests against PostgreSQL");
    integration_pg_step.dependOn(&run_integration_pg.step);

    // Forced write-path undo fallback: the SAME integration suite (incl. the reorg
    // reconcile + rollback regressions) with SQLite doctored to server_side_undo=false
    // — proves the application-side capture is restore-equivalent to the triggers.
    const run_integration_fallback = b.addRunArtifact(integration_tests);
    run_integration_fallback.setCwd(b.path("."));
    run_integration_fallback.setEnvironmentVariable("TEST_FORCE_WRITE_PATH_UNDO", "1");
    const integration_fallback_step = b.step("test-integration-fallback", "Run integration tests with forced write-path undo capture");
    integration_fallback_step.dependOn(&run_integration_fallback.step);

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
    graphql_tests.root_module.link_libc = true;
    graphql_tests.root_module.linkSystemLibrary("sqlite3", .{});

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
    graphql_features_tests.root_module.link_libc = true;
    graphql_features_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_graphql_features_tests = b.addRunArtifact(graphql_features_tests);
    const graphql_features_test_step = b.step("test-graphql-features", "Run all GraphQL feature tests");
    graphql_features_test_step.dependOn(&run_graphql_features_tests.step);

    // Also add to the main graphql test step
    graphql_test_step.dependOn(&run_graphql_features_tests.step);

    // Cost-model integration tests: real queries through the parser + analyzer,
    // proving the DoS governor's verdicts end-to-end (not just unit-level).
    const complexity_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphql/complexity_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graphql", .module = graphql_lib_mod },
            },
        }),
    });
    const run_complexity_integration_tests = b.addRunArtifact(complexity_integration_tests);
    graphql_test_step.dependOn(&run_complexity_integration_tests.step);

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

    // ENSIP-15 normalization wrapper tests (needs the z_ens_normalize module)
    const normalize_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/utils/ens_normalize.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
            },
        }),
    });
    normalize_tests.root_module.link_libc = true;
    const run_normalize_tests = b.addRunArtifact(normalize_tests);
    const normalize_test_step = b.step("test-normalize", "Run ENSIP-15 normalization tests");
    normalize_test_step.dependOn(&run_normalize_tests.step);

    // Indexer tests: runs the indexer's inline tests (abi_eth) and the pure helpers
    // it relies on (DNS wire decode, token-id math, calldata + V1 name decoding) that
    // the lib.zig-rooted `test` step never reaches, plus new decodeDnsWireFormat cases.
    const indexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "eth", .module = eth_module },
            },
        }),
    });
    indexer_tests.root_module.link_libc = true;
    indexer_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_indexer_tests = b.addRunArtifact(indexer_tests);
    run_indexer_tests.setCwd(b.path("."));
    const indexer_test_step = b.step("test-indexer", "Run indexer + helper unit tests");
    indexer_test_step.dependOn(&run_indexer_tests.step);

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
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    api_tests.root_module.link_libc = true;
    api_tests.root_module.linkSystemLibrary("sqlite3", .{});
    // The handler @embedFiles introspection.json; without this dependency a
    // schema.graphql change compiles tests against the STALE embedded schema
    // (the validator then rejects newly declared arguments).
    api_tests.step.dependOn(&generate_schema.step);
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
    events_tests.root_module.link_libc = true;
    events_tests.root_module.linkSystemLibrary("sqlite3", .{});

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
    storage_names_tests.root_module.link_libc = true;
    storage_names_tests.root_module.linkSystemLibrary("sqlite3", .{});

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
    storage_resolvers_tests.root_module.link_libc = true;
    storage_resolvers_tests.root_module.linkSystemLibrary("sqlite3", .{});

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
    storage_roles_tests.root_module.link_libc = true;
    storage_roles_tests.root_module.linkSystemLibrary("sqlite3", .{});

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
    storage_webhooks_tests.root_module.link_libc = true;
    storage_webhooks_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_webhooks_tests = b.addRunArtifact(storage_webhooks_tests);
    run_storage_webhooks_tests.setCwd(b.path("."));

    // Storage tests - init-gap heal ledger
    const storage_heal_targets_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/heal_targets_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_heal_targets_tests.root_module.link_libc = true;
    storage_heal_targets_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_heal_targets_tests = b.addRunArtifact(storage_heal_targets_tests);
    run_storage_heal_targets_tests.setCwd(b.path("."));

    // Storage tests - bulk-flush batch inserts (events + names)
    const storage_batch_insert_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/batch_insert_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_batch_insert_tests.root_module.link_libc = true;
    storage_batch_insert_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_batch_insert_tests = b.addRunArtifact(storage_batch_insert_tests);
    run_storage_batch_insert_tests.setCwd(b.path("."));

    // Storage tests - dispatch-scoped name prefetch (lookup mirroring + write invalidation)
    const storage_name_prefetch_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/name_prefetch_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_name_prefetch_tests.root_module.link_libc = true;
    storage_name_prefetch_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_name_prefetch_tests = b.addRunArtifact(storage_name_prefetch_tests);
    run_storage_name_prefetch_tests.setCwd(b.path("."));

    // Storage tests - registry_entries (on-chain Entry mirror + reachability cascade)
    const storage_registry_entries_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/registry_entries_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_registry_entries_tests.root_module.link_libc = true;
    storage_registry_entries_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_registry_entries_tests = b.addRunArtifact(storage_registry_entries_tests);
    run_storage_registry_entries_tests.setCwd(b.path("."));

    // Query abstraction tests (the backend statement seam) — uses the `lib`
    // module (in-memory DB via Database.initWithoutSchema).
    const storage_query_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/query_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_query_tests.root_module.link_libc = true;
    storage_query_tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_storage_query_tests = b.addRunArtifact(storage_query_tests);
    run_storage_query_tests.setCwd(b.path("."));

    // PostgreSQL dialect + placeholder-lexer golden tests (pure string-gen; no pg.zig
    // and no running Postgres — validates the Phase-4 dialect against fixed expectations).
    const storage_pg_dialect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/postgres_dialect_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    storage_pg_dialect_tests.root_module.link_libc = true;
    storage_pg_dialect_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_storage_pg_dialect_tests = b.addRunArtifact(storage_pg_dialect_tests);
    run_storage_pg_dialect_tests.setCwd(b.path("."));

    // Phase 4 dependency-integration gate: pg.zig compiles + its API imports under
    // Zig 0.15.2 (TLS off ⇒ no openssl/libc). Its own `test-pg` step (not in the
    // default `test`) until the real driver + a live Postgres land.
    const pg_smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/pg_smoke_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    const run_pg_smoke_tests = b.addRunArtifact(pg_smoke_tests);
    run_pg_smoke_tests.setCwd(b.path("."));

    // Live PostgreSQL backend-driver tests (the Backend/Statement SPI on pg.zig).
    const pg_driver_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/postgres_driver_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    pg_driver_tests.root_module.link_libc = true;
    pg_driver_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_pg_driver_tests = b.addRunArtifact(pg_driver_tests);
    run_pg_driver_tests.setCwd(b.path("."));

    const pg_test_step = b.step("test-pg", "Run PostgreSQL driver/dependency tests (Phase 4)");
    pg_test_step.dependOn(&run_pg_smoke_tests.step);
    pg_test_step.dependOn(&run_pg_driver_tests.step);

    // Conflict-key map: the only guard on the schema-derived ON CONFLICT targets
    // (SQLite ignores them, so they are invisible to behavioral tests).
    const storage_schema_keys_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/storage/schema_keys.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_storage_schema_keys_tests = b.addRunArtifact(storage_schema_keys_tests);
    run_storage_schema_keys_tests.setCwd(b.path("."));

    // Driver-conformance suite: the executable spec for the backend SPI
    // (docs/backend-spi.md). Runs against SQLite here and against PostgreSQL
    // in the test-storage-pg lane — both shipped drivers must pass it, and a
    // third-party driver passing it satisfies the published contract.
    const backend_conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/backend_conformance_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    backend_conformance_tests.root_module.link_libc = true;
    backend_conformance_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_backend_conformance_tests = b.addRunArtifact(backend_conformance_tests);
    run_backend_conformance_tests.setCwd(b.path("."));

    // Session-pool tests: degenerate SQLite semantics here; the real multi-session
    // pool (distinct sessions, exhaustion blocking, concurrent queries) runs in the
    // test-storage-pg lane.
    const pool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/storage/pool_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    pool_tests.root_module.link_libc = true;
    pool_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_pool_tests = b.addRunArtifact(pool_tests);
    run_pool_tests.setCwd(b.path("."));

    // Storage test step
    const storage_test_step = b.step("test-storage", "Run storage module tests");
    storage_test_step.dependOn(&run_storage_names_tests.step);
    storage_test_step.dependOn(&run_storage_resolvers_tests.step);
    storage_test_step.dependOn(&run_storage_roles_tests.step);
    storage_test_step.dependOn(&run_storage_webhooks_tests.step);
    storage_test_step.dependOn(&run_storage_heal_targets_tests.step);
    storage_test_step.dependOn(&run_storage_batch_insert_tests.step);
    storage_test_step.dependOn(&run_storage_name_prefetch_tests.step);
    storage_test_step.dependOn(&run_storage_registry_entries_tests.step);
    storage_test_step.dependOn(&run_storage_query_tests.step);
    storage_test_step.dependOn(&run_storage_schema_keys_tests.step);
    storage_test_step.dependOn(&run_storage_pg_dialect_tests.step);
    storage_test_step.dependOn(&run_backend_conformance_tests.step);
    storage_test_step.dependOn(&run_pool_tests.step);

    // Cross-backend lane: re-run the storage suites against PostgreSQL. TEST_BACKEND=postgres
    // makes helpers.createTestDatabase open the local ensv2_test and reset its schema per
    // test. Reuses the same compiled test binaries — just a second run with the env set.
    // Requires a live Postgres (like test-pg); not part of the default `test` step.
    const storage_pg_test_step = b.step("test-storage-pg", "Run storage suites against PostgreSQL");
    for ([_]*std.Build.Step.Compile{
        storage_names_tests,
        storage_resolvers_tests,
        storage_roles_tests,
        storage_registry_entries_tests,
        storage_query_tests,
        storage_webhooks_tests,
        storage_heal_targets_tests,
        storage_batch_insert_tests,
        storage_name_prefetch_tests,
        backend_conformance_tests,
        pool_tests,
    }) |compile| {
        const run = b.addRunArtifact(compile);
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("TEST_BACKEND", "postgres");
        storage_pg_test_step.dependOn(&run.step);
    }

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
    test_step.dependOn(&run_storage_heal_targets_tests.step);
    test_step.dependOn(&run_storage_batch_insert_tests.step);
    test_step.dependOn(&run_storage_name_prefetch_tests.step);
    test_step.dependOn(&run_storage_registry_entries_tests.step);
    test_step.dependOn(&run_backend_conformance_tests.step);
    test_step.dependOn(&run_pool_tests.step);
    test_step.dependOn(&run_normalize_tests.step);
    test_step.dependOn(&run_indexer_tests.step);

    // Resolution layer tests (query-time eth_call + resolution cache). Rooted
    // inside src/ so it reaches the storage, rpc, and type modules by relative
    // import; the {ens_normalize, eth, pg} trio matches the other src-rooted lanes.
    const resolve_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/resolve_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    resolve_tests.root_module.link_libc = true;
    resolve_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_resolve_tests = b.addRunArtifact(resolve_tests);
    run_resolve_tests.setCwd(b.path("."));
    const resolve_test_step = b.step("test-resolve", "Run resolution layer tests");
    resolve_test_step.dependOn(&run_resolve_tests.step);
    test_step.dependOn(&run_resolve_tests.step);

    // Fuzz lane: hostile-input decoders/parsers (smoke-run in test-all; real
    // exploration via `zig build test-fuzz --fuzz`). Same src-rooted module trio.
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ens_normalize", .module = ens_normalize.module("z_ens_normalize") },
                .{ .name = "eth", .module = eth_module },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    fuzz_tests.root_module.link_libc = true;
    fuzz_tests.root_module.linkSystemLibrary("sqlite3", .{});
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.setCwd(b.path("."));
    const fuzz_test_step = b.step("test-fuzz", "Run fuzz targets (smoke; add --fuzz to explore)");
    fuzz_test_step.dependOn(&run_fuzz_tests.step);

    // GraphQL conformance harness: drives the real GraphQLHandler end-to-end against
    // a seeded in-memory DB (deterministic golden responses). Rooted in tests/ and
    // reaches the handler + Database via the SAME `lib` module `helpers` uses, so
    // there is exactly one Database type across the module graph.
    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance/runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
        .test_runner = .{ .path = b.path("tests/conformance/quiet_runner.zig"), .mode = .simple },
    });
    conformance_tests.root_module.link_libc = true;
    conformance_tests.root_module.linkSystemLibrary("sqlite3", .{});
    // Same stale-introspection guard as api_tests: golden runs must compile
    // against the schema in the working tree, not a leftover generated file.
    conformance_tests.step.dependOn(&generate_schema.step);
    const run_conformance_tests = b.addRunArtifact(conformance_tests);
    run_conformance_tests.setCwd(b.path("."));
    const conformance_test_step = b.step("test-conformance", "Run GraphQL conformance golden harness");
    conformance_test_step.dependOn(&run_conformance_tests.step);

    // MCP protocol tests: JSON-RPC framing + tool dispatch over a seeded DB
    // (transport-free core). Depends on generate_schema: mcp.zig embeds the
    // generator-copied src/api/schema.graphql.
    const mcp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/graphql/mcp_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "helpers", .module = helpers_mod },
                .{ .name = "lib", .module = lib_mod },
            },
        }),
    });
    mcp_tests.root_module.link_libc = true;
    mcp_tests.root_module.linkSystemLibrary("sqlite3", .{});
    mcp_tests.step.dependOn(&generate_schema.step);
    const run_mcp_tests = b.addRunArtifact(mcp_tests);
    run_mcp_tests.setCwd(b.path("."));
    const mcp_test_step = b.step("test-mcp", "Run MCP agent endpoint tests");
    mcp_test_step.dependOn(&run_mcp_tests.step);
    test_step.dependOn(&run_mcp_tests.step);
    // Manifest-driven config (Task 08). Uses the quiet runner because the validation tests
    // deliberately trigger std.log.err on bad-address/wrong-chain/unknown-contract paths;
    // setCwd(.) so it reads the committed manifests/ reference files.
    const manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/manifest_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = .{ .path = b.path("tests/conformance/quiet_runner.zig"), .mode = .simple },
    });
    manifest_tests.root_module.link_libc = true;
    const run_manifest_tests = b.addRunArtifact(manifest_tests);
    run_manifest_tests.setCwd(b.path("."));
    const manifest_test_step = b.step("test-manifest", "Run contract-manifest loader tests");
    manifest_test_step.dependOn(&run_manifest_tests.step);

    // Aggregate lane: every SQLite-backed test lane behind one target so CI has a
    // single entry point and new lanes join here. The Postgres-backed lanes
    // (test-*-pg) are intentionally excluded — they require a live database.
    const test_all_step = b.step("test-all", "Run every SQLite-backed test lane");
    test_all_step.dependOn(test_step);
    test_all_step.dependOn(integration_test_step);
    test_all_step.dependOn(integration_fallback_step);
    test_all_step.dependOn(graphql_test_step);
    test_all_step.dependOn(graphql_features_test_step);
    test_all_step.dependOn(filter_test_step);
    test_all_step.dependOn(normalize_test_step);
    test_all_step.dependOn(indexer_test_step);
    test_all_step.dependOn(json_writer_test_step);
    test_all_step.dependOn(api_test_step);
    test_all_step.dependOn(events_test_step);
    test_all_step.dependOn(apollo_test_step);
    test_all_step.dependOn(variables_test_step);
    test_all_step.dependOn(address_validation_test_step);
    test_all_step.dependOn(storage_test_step);
    test_all_step.dependOn(resolve_test_step);
    test_all_step.dependOn(conformance_test_step);
    test_all_step.dependOn(manifest_test_step);
    test_all_step.dependOn(fuzz_test_step);
}
