const std = @import("std");

// The indexer's inline tests (abi_eth) and the pure helpers it relies on (DNS wire
// decode, token-id/canonical-id math, calldata decoding, V1 name helpers) are NOT
// reached by the lib.zig-rooted `test` step — so they never ran in CI. Pull them in
// here so `zig build test-indexer` executes them, plus the new coverage below.
// Rooted under src/ so the relative imports stay inside the module path (Zig 0.15
// forbids @import escaping the module root, which a tests/ location would do).
comptime {
    _ = @import("indexer/abi_eth.zig");
    _ = @import("utils/dns.zig");
    _ = @import("utils/calldata_decoder.zig");
    _ = @import("utils/v1_names.zig");
    _ = @import("types/token_id.zig");
    _ = @import("indexer/replay.zig");
    _ = @import("indexer/v2/handlers_resolver_records.zig");
    _ = @import("indexer/discovery_backfill.zig");
    _ = @import("indexer/placeholders.zig");
    _ = @import("indexer/write_buffer.zig");
    _ = @import("indexer/cdp_intake.zig");
    _ = @import("indexer/sync_watchdog.zig");
}

const dns = @import("utils/dns.zig");
const token_id = @import("types/token_id.zig");
const models_mod = @import("types/models.zig");

fn expectDns(a: std.mem.Allocator, wire: []const u8, want: []const u8) !void {
    const got = (try dns.decodeDNSNameToString(a, wire)) orelse return error.TestUnexpectedResult;
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

// Pins the semantics the V2 resolver handlers rely on after the duplicate
// decoder was folded into utils/dns.zig: identical dotted-name output on valid
// input, `null` for THE ROOT NAME and nothing else, and a propagated
// `error.InvalidDNSEncoding` for a malformed encoding.
//
// This test previously asserted that malformed input and the root name BOTH
// produced null. That is what let handleNamedResourceKind discard three real
// root-name records as undecodable, so the two outcomes are now pinned apart.
test "decodeDNSNameToString: dotted name; null means root; malformed errors" {
    const a = std.testing.allocator;
    try expectDns(a, "\x03eth\x00", "eth");
    try expectDns(a, "\x05alice\x03eth\x00", "alice.eth");
    try expectDns(a, "\x03sub\x05alice\x03eth\x00", "sub.alice.eth");
    // A missing root terminator still decodes (the loop ends at data.len).
    try expectDns(a, "\x03eth", "eth");
    // Bytes after the root terminator are ignored, not an error.
    try expectDns(a, "\x03eth\x00junk", "eth");
    // Zero labels is the root name — reported as null, and NOT as a failure.
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, "\x00"));
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, ""));
    // A label length that runs past the payload is malformed. It must surface as
    // an error so utils.isMalformedEventError can skip that one event with its
    // coordinates, instead of masquerading as the root name.
    try std.testing.expectError(error.InvalidDNSEncoding, dns.decodeDNSNameToString(a, "\x05ab"));
}

test "getCanonicalId: clears the low 32 version bits (EAC/token-id stability)" {
    // A versioned token id and its canonical id differ only in the low 32 bits.
    const high: u256 = 0xABCDEF; // the canonical (high) bits
    const versioned = (high << 32) | 0x12345678; // a version in the low 32 bits
    try std.testing.expectEqual(high << 32, token_id.getCanonicalId(versioned));
    // Already-canonical (low 32 bits zero) is unchanged; zero stays zero (resolver EAC).
    try std.testing.expectEqual(high << 32, token_id.getCanonicalId(high << 32));
    try std.testing.expectEqual(@as(u256, 0), token_id.getCanonicalId(0));
}

test "Approved event signature matches the deployed PublicResolver topic" {
    // Externally verified topic0 (keccak of the canonical signature); guards
    // the signature string in abi.zig against drift.
    const abi = @import("indexer/abi.zig");
    var expect_bytes: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expect_bytes, "f0ddb3b04746704017f9aa8bd728fcc2c1d11675041205350018915f5e4750a0");
    try std.testing.expectEqualSlices(u8, &expect_bytes, &abi.EventSignatures.approved_hash.bytes);
}

test "basenames flow: controller preimage + registrar registration land under base.eth" {
    // Mini-flow through the REAL handlers with NETWORK=base: the controller event
    // supplies the label preimage, then the registrar event materializes
    // <label>.base.eth with the base.eth parent node — proving the root
    // parameterization end-to-end. The same registrar path on eth networks
    // asserts the fixed parent node (was namehash("<empty>.eth") via
    // computeEthNamehash("")).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    cfg.network = .base;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const indexer_mod = @import("indexer/indexer.zig");
    var idx = try indexer_mod.Indexer.init(allocator, io, cfg, &database, null);
    defer idx.deinit();

    const hash_mod = @import("types/hash.zig");
    const Hash = hash_mod.Hash;
    const Address = @import("types/address.zig").Address;
    const abi = @import("indexer/abi.zig");
    const v1_names = @import("utils/v1_names.zig");

    // Cross-implementation check: the incremental child namehash equals the full
    // namehash parser's answer, and the Indexer cached the base.eth root node.
    const base_root = try hash_mod.namehash(allocator, "base.eth");
    const expected_nh = try hash_mod.namehash(allocator, "jesse.base.eth");
    const child = v1_names.computeChildNamehash(base_root, "jesse");
    try std.testing.expectEqualSlices(u8, &expected_nh.bytes, &child.bytes);
    try std.testing.expectEqualSlices(u8, &base_root.bytes, &idx.root_node.bytes);

    const owner = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var owner_topic = Hash.zero;
    @memcpy(owner_topic.bytes[12..32], &owner.bytes);
    const label_hash = v1_names.computeLabelHash("jesse");

    // (1) Basenames controller NameRegistered (4-arg): data = (string, uint256).
    // ABI layout: [offset=0x40][expires][len=5]["jesse" padded to 32].
    var reg_data = [_]u8{0} ** 128;
    reg_data[31] = 0x40;
    std.mem.writeInt(u256, reg_data[32..64], 2_000_000_000, .big);
    reg_data[95] = 5;
    @memcpy(reg_data[96..101], "jesse");
    var reg_topics = [_]Hash{ abi.EventSignatures.basenames_controller_name_registered_hash, label_hash, owner_topic };
    try idx.handleBasenamesControllerNameRegistered(.v1, .{
        .address = try Address.fromHex("0x4ccb0bb02fcaba27e82a56646e81d8c5bc4119a5"),
        .topics = reg_topics[0..],
        .data = reg_data[0..],
        .block_number = 100,
        .transaction_hash = Hash.zero,
        .transaction_index = 0,
        .log_index = 0,
        .removed = false,
        .block_timestamp = 1_700_000_000,
        .block_hash = null,
    });

    // (2) Registrar NameRegisteredWithRecord — the CANONICAL Basenames registration
    // event (registerWithRecord flow): topics (sig, tokenId=labelhash, owner),
    // data = (uint256 expires, address resolver, uint64 ttl). The label is cached
    // from step 1, so this takes the label-known path and applies the resolver.
    const resolver_addr = try Address.fromHex("0xcccccccccccccccccccccccccccccccccccccccc");
    var wr_data = [_]u8{0} ** 96;
    std.mem.writeInt(u256, wr_data[0..32], 2_000_000_000, .big);
    @memcpy(wr_data[44..64], &resolver_addr.bytes);
    var wr_topics = [_]Hash{ abi.EventSignatures.basenames_registrar_name_registered_with_record_hash, label_hash, owner_topic };
    try idx.handleBasenamesRegistrarNameRegisteredWithRecord(.v1, .{
        .address = try Address.fromHex("0x03c4738ee98ae44591e1a4a4f3cab6641d95dd9a"),
        .topics = wr_topics[0..],
        .data = wr_data[0..],
        .block_number = 101,
        .transaction_hash = Hash.zero,
        .transaction_index = 0,
        .log_index = 1,
        .removed = false,
        .block_timestamp = 1_700_000_000,
        .block_hash = null,
    });

    const row_opt = try database.getNameByNamehashAndProtocol(expected_nh, .v1);
    try std.testing.expect(row_opt != null);
    var row = row_opt.?;
    defer row.deinit(database.allocator);
    try std.testing.expectEqualStrings("jesse.base.eth", row.name.?);
    try std.testing.expectEqualStrings("base.eth", row.parent_name.?);
    try std.testing.expectEqualSlices(u8, &base_root.bytes, &row.parent_namehash.bytes);
    try std.testing.expect(row.resolver.eql(resolver_addr));
}

test "Basenames controller signatures match independently computed topics" {
    // topic0 values computed independently (keccak-256 of the canonical
    // signatures); guards the abi.zig signature strings against drift.
    const abi = @import("indexer/abi.zig");
    const cases = .{
        .{ abi.EventSignatures.basenames_controller_name_registered_hash, "0667086d08417333ce63f40d5bc2ef6fd330e25aaaf317b7c489541f8fe600fa" },
        .{ abi.EventSignatures.basenames_controller_name_renewed_hash, "93bc1a84707231b1d9552157299797c64a1a8c5bc79f05153716630c9c4936fc" },
        .{ abi.EventSignatures.basenames_registrar_name_registered_with_record_hash, "fd724d251af149ea2929b9061ddab2bb31e2d87778cc0acfa1d68add62e222e8" },
    };
    inline for (cases) |case| {
        var expect_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expect_bytes, case[1]);
        const got: [32]u8 = case[0].bytes;
        try std.testing.expectEqualSlices(u8, &expect_bytes, &got);
    }
}

test "Named*Resource signatures match the contracts-v2 PermissionedResolver topics" {
    const abi = @import("indexer/abi.zig");
    const cases = .{
        .{ abi.EventSignatures.named_resource_hash, "737038e72be1d204e2c7336c20bff2169d9dffe11face28c5969af4ecce04f67" },
        .{ abi.EventSignatures.named_text_resource_hash, "ab228e072dd20e63d6891264ea8f6a2459e6852ab494b707970f978ba630859c" },
        .{ abi.EventSignatures.named_data_resource_hash, "db7aa4f21d01358b79d5574f3f3f6805f4f97606c53cb70598063387352206ac" },
        .{ abi.EventSignatures.named_addr_resource_hash, "2fe6caf984256b1a1844b92f52cf88703e829b07ce397a6c7fcf1f779db7a185" },
    };
    inline for (cases) |case| {
        var expect_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expect_bytes, case[1]);
        const got: [32]u8 = case[0].bytes;
        try std.testing.expectEqualSlices(u8, &expect_bytes, &got);
    }
}

fn dispatchV2(idx: *@import("indexer/indexer.zig").Indexer, table: anytype, log: @import("rpc/client.zig").Log) !void {
    for (table) |cfg| {
        if (cfg.event_hash.eql(log.topics[0])) return cfg.handler(idx, .v2, log);
    }
    return error.EventNotInTable;
}

fn syntheticLog(address: @import("types/address.zig").Address, topics: []@import("types/hash.zig").Hash, data: []u8, block_number: u64, block_timestamp: u64) @import("rpc/client.zig").Log {
    var tx_hash = @import("types/hash.zig").Hash.zero;
    std.mem.writeInt(u64, tx_hash.bytes[24..32], block_number, .big);
    return .{
        .address = address,
        .topics = topics,
        .data = data,
        .block_number = block_number,
        .transaction_hash = tx_hash,
        .transaction_index = 0,
        .log_index = 0,
        .removed = false,
        .block_timestamp = block_timestamp,
        .block_hash = null,
    };
}

test "ETH registry fetch set covers every PermissionedRegistry event of the deployed ETHRegistry" {
    const abi = @import("indexer/abi.zig");
    const Indexer = @import("indexer/indexer.zig").Indexer;
    const datastore = [_]@import("types/hash.zig").Hash{ abi.EventSignatures.subregistry_updated_hash, abi.EventSignatures.resolver_updated_hash };
    for (Indexer.SUBREGISTRY_ENS_EVENTS) |sub| {
        var covered = false;
        for (Indexer.ETH_REGISTRY_EVENTS) |eth| covered = covered or eth.event_hash.eql(sub.event_hash);
        for (datastore) |h| covered = covered or h.eql(sub.event_hash);
        if (!covered) std.debug.print("ETH registry does not fetch {s}\n", .{sub.name});
        try std.testing.expect(covered);
    }

    const cases = .{
        .{ abi.EventSignatures.label_reserved_hash, "734822851860327a80c624af1471efac6bb0ac641852fc6c7bfeeee3202ae6a8" },
        .{ abi.EventSignatures.label_unregistered_hash, "5293e83951c7b759c1ef192ceed240dc2caa652e29ddbd95cafe1d88e5a9cea8" },
        .{ abi.EventSignatures.expiry_updated_hash, "3260962d42d8f7ae0af25cbfdb2983c214a859cfa2ac6df8ea29b534c267d429" },
        .{ abi.EventSignatures.parent_updated_hash, "e49f02c945e0ee4a8d961a371289bd054aa21d9ca1b73250ffd4880eb708cff4" },
        .{ abi.EventSignatures.registry_created_hash, "ce2f8c55f0f6fbc489417a09291281b739419d412c063df417ab075e6f052687" },
    };
    inline for (cases) |case| {
        var expect_bytes: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expect_bytes, case[1]);
        const got: [32]u8 = case[0].bytes;
        try std.testing.expectEqualSlices(u8, &expect_bytes, &got);
    }
}

test "LabelReserved from the main ETH registry creates an owner-less <label>.eth name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const Indexer = @import("indexer/indexer.zig").Indexer;
    var idx = try Indexer.init(allocator, threaded.io(), cfg, &database, null);
    defer idx.deinit();

    const hash_mod = @import("types/hash.zig");
    const Hash = hash_mod.Hash;
    const Address = @import("types/address.zig").Address;
    const abi = @import("indexer/abi.zig");
    const v1_names = @import("utils/v1_names.zig");

    const eth_registry = idx.getEthRegistry(.v2);
    if (eth_registry.isZero()) return;

    const label_hash = v1_names.computeLabelHash("reserved");
    const reserved_token_id = std.mem.readInt(u256, &label_hash.bytes, .big) & ~@as(u256, 0xffffffff);
    var token_topic = Hash.zero;
    std.mem.writeInt(u256, &token_topic.bytes, reserved_token_id, .big);
    const sender = try Address.fromHex("0xbe68ff9afc7d5a1864ffef5c82de0a1c13e6b529");
    var sender_topic = Hash.zero;
    @memcpy(sender_topic.bytes[12..32], &sender.bytes);

    var data = [_]u8{0} ** 128;
    data[31] = 0x40;
    std.mem.writeInt(u256, data[32..64], 1_900_000_000, .big);
    data[95] = 8;
    @memcpy(data[96..104], "reserved");
    var topics = [_]Hash{ abi.EventSignatures.label_reserved_hash, token_topic, label_hash, sender_topic };
    try dispatchV2(&idx, Indexer.ETH_REGISTRY_EVENTS, syntheticLog(eth_registry, topics[0..], data[0..], 200, 1_700_000_200));

    const nh = try hash_mod.namehash(allocator, "reserved.eth");
    var row = (try database.getNameByNamehashAndProtocol(nh, .v2)).?;
    defer row.deinit(database.allocator);
    try std.testing.expectEqualStrings("reserved.eth", row.name.?);
    try std.testing.expect(row.registry.eql(eth_registry));
    try std.testing.expect(row.owner.isZero());
    try std.testing.expectEqual(@as(u64, 1_900_000_000), row.expiry);
}

test "seeded registries take RegistryCreated (root) or their first SubregistryUpdated (eth), live and on replay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const Indexer = @import("indexer/indexer.zig").Indexer;
    var idx = try Indexer.init(allocator, threaded.io(), cfg, &database, null);
    defer idx.deinit();

    const hash_mod = @import("types/hash.zig");
    const Hash = hash_mod.Hash;
    const Address = @import("types/address.zig").Address;
    const abi = @import("indexer/abi.zig");

    const eth_registry = idx.getEthRegistry(.v2);
    const root_registry = cfg.v2_contracts.root_registry;
    if (eth_registry.isZero() or root_registry.isZero()) return;

    try idx.seedV2Registries();
    const sub = try Address.fromHex("0x9999999999999999999999999999999999999999");
    try database.insertRegistry(.{
        .address = sub,
        .protocol = .v2,
        .name = "sub.eth",
        .namehash = try hash_mod.namehash(allocator, "sub.eth"),
        .parent_registry = eth_registry,
        .created_block = 700,
        .created_at = 1_700_000_700,
    });

    var no_data = [_]u8{};
    var root_topics = [_]Hash{abi.EventSignatures.registry_created_hash};
    var eth_topics = [_]Hash{abi.EventSignatures.registry_created_hash};
    var sub_topics = [_]Hash{abi.EventSignatures.registry_created_hash};
    try dispatchV2(&idx, Indexer.SUBREGISTRY_ENS_EVENTS, syntheticLog(root_registry, root_topics[0..], no_data[0..], 400, 1_700_000_400));
    try dispatchV2(&idx, Indexer.ETH_REGISTRY_EVENTS, syntheticLog(eth_registry, eth_topics[0..], no_data[0..], 500, 1_700_000_500));
    try dispatchV2(&idx, Indexer.SUBREGISTRY_ENS_EVENTS, syntheticLog(sub, sub_topics[0..], no_data[0..], 650, 1_700_000_650));

    const expectCreation = struct {
        fn run(db: *db_mod.Database, addr: Address, block: u64, ts: i64) !void {
            const reg = (try db.getRegistry(.v2, addr)).?;
            try std.testing.expectEqual(block, reg.created_block);
            try std.testing.expectEqual(ts, reg.created_at);
        }
    }.run;
    try expectCreation(&database, root_registry, 400, 1_700_000_400);
    try expectCreation(&database, eth_registry, cfg.v2_contracts.v2_deployment_block, 0);
    try expectCreation(&database, sub, 700, 1_700_000_700);

    const subregistryUpdated = struct {
        fn topics(label: []const u8, subregistry: Address) [4]Hash {
            const label_hash = @import("utils/v1_names.zig").computeLabelHash(label);
            var token_topic = Hash.zero;
            std.mem.writeInt(u256, &token_topic.bytes, std.mem.readInt(u256, &label_hash.bytes, .big) & ~@as(u256, 0xffffffff), .big);
            var sub_topic = Hash.zero;
            @memcpy(sub_topic.bytes[12..32], &subregistry.bytes);
            return .{ abi.EventSignatures.subregistry_updated_hash, token_topic, sub_topic, Hash.zero };
        }
    }.topics;
    const seedName = struct {
        fn run(ix: *Indexer, a: std.mem.Allocator, name: []const u8, label: []const u8, parent: []const u8, registry: Address) !void {
            const label_hash = @import("utils/v1_names.zig").computeLabelHash(label);
            const canonical = std.mem.readInt(u256, &label_hash.bytes, .big) & ~@as(u256, 0xffffffff);
            try ix.insertName(.{
                .name = name,
                .label = label,
                .label_hash = label_hash,
                .parent_name = parent,
                .parent_namehash = try hash_mod.namehash(a, parent),
                .protocol = .v2,
                .registry = registry,
                .owner = Address.zero,
                .registrant = Address.zero,
                .resolver = Address.zero,
                .token_id = canonical,
                .canonical_id = canonical,
                .token_version = 0,
                .namehash = try hash_mod.namehash(a, name),
                .expiry = 0,
                .registry_locked = false,
                .migrated = false,
                .created_block = 300,
                .created_at = 1_700_000_300,
                .registered_at = 1_700_000_300,
                .updated_block = 300,
                .updated_at = 1_700_000_300,
                .is_wrapped = false,
                .wrapper_fuses = null,
                .wrapper_expiry = null,
                .is_v1_name = false,
                .v1_label_hash = null,
            });
        }
    }.run;
    try seedName(&idx, allocator, "eth", "eth", "", root_registry);
    try seedName(&idx, allocator, "sub.eth", "sub", "eth", eth_registry);

    var link_eth = subregistryUpdated("eth", eth_registry);
    var link_sub = subregistryUpdated("sub", sub);
    try dispatchV2(&idx, Indexer.SUBREGISTRY_ENS_EVENTS, syntheticLog(root_registry, link_eth[0..], no_data[0..], 501, 1_700_000_501));
    try dispatchV2(&idx, Indexer.SUBREGISTRY_ENS_EVENTS, syntheticLog(eth_registry, link_sub[0..], no_data[0..], 800, 1_700_000_800));
    try expectCreation(&database, eth_registry, 501, 1_700_000_501);
    try expectCreation(&database, sub, 700, 1_700_000_700);

    {
        var count_q = try db_mod.Query.init(&database, "SELECT count(*) FROM registries WHERE protocol = 'v2'");
        defer count_q.deinit();
        try std.testing.expect(try count_q.step());
        try std.testing.expectEqual(@as(i64, 3), count_q.getInt64(0));
    }

    try @import("indexer/replay.zig").replayV2RegistriesCore(&idx);
    try expectCreation(&database, root_registry, 400, 1_700_000_400);
    try expectCreation(&database, eth_registry, 501, 1_700_000_501);
}

test "buffered V2 name inserts are landed by the names barrier before any direct names access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const indexer_mod = @import("indexer/indexer.zig");
    var idx = try indexer_mod.Indexer.init(allocator, io, cfg, &database, null);
    defer idx.deinit();

    const models = @import("types/models.zig");
    const Hash = @import("types/hash.zig").Hash;
    const Address = @import("types/address.zig").Address;
    const nh_a = Hash{ .bytes = [_]u8{0xa1} ** 32 };
    const nh_b = Hash{ .bytes = [_]u8{0xb2} ** 32 };
    var owner: Address = .{ .bytes = [_]u8{0} ** 20 };
    owner.bytes[19] = 1;
    const mk = struct {
        fn name(nh: Hash, label: []const u8, full: []const u8, reg: Address, own: Address) models.Name {
            return .{ .name = full, .label = label, .parent_name = "eth", .namehash = nh, .protocol = .v2, .label_hash = Hash.zero, .parent_namehash = Hash.zero, .registry = reg, .owner = own, .registrant = own, .resolver = Address.zero, .token_id = 0, .canonical_id = 0, .token_version = 0, .expiry = 1_000, .registry_locked = false, .migrated = false, .created_block = 10, .created_at = 100, .registered_at = 100, .updated_block = 10, .updated_at = 100, .is_wrapped = false, .wrapper_fuses = null, .wrapper_expiry = null, .is_v1_name = false, .v1_label_hash = null };
        }
    };
    const countNames = struct {
        fn run(db: *db_mod.Database) !i64 {
            var q = try db_mod.Query.init(db, "SELECT COUNT(*) FROM names");
            defer q.deinit();
            _ = try q.step();
            return q.getInt64(0);
        }
    };

    // Buffered window: active buffer, disarmed cursor, barrier armed like the driver does.
    idx.write_buffer.active = true;
    idx.reorg_arm = false;
    database.names_barrier = .{ .ctx = &idx, .flush = indexer_mod.Indexer.namesBarrierFlush };
    defer database.names_barrier = null;

    // Init seeds the TLD rows; measure against that baseline.
    const base = try countNames.run(&database);
    try idx.insertName(mk.name(nh_a, "alpha", "alpha.eth", idx.getEthRegistry(.v2), owner));
    try std.testing.expectEqual(base, try countNames.run(&database));
    try std.testing.expect(idx.write_buffer.hasPendingNames());

    // A direct names write lands the pending row first, then applies.
    try database.updateNameExpiry(nh_a, 2_000);
    try std.testing.expect(!idx.write_buffer.hasPendingNames());
    try std.testing.expectEqual(base + 1, try countNames.run(&database));
    const row = (try database.getNameByNamehash(nh_a)).?;
    var row_mut = row;
    defer row_mut.deinit(allocator);
    try std.testing.expectEqual(@as(u64, 2_000), row_mut.expiry);

    // A buffered insert followed by a direct delete removes the row, never resurrects it.
    try idx.insertName(mk.name(nh_b, "beta", "beta.eth", idx.getEthRegistry(.v2), owner));
    try database.deleteNameByNamehash(nh_b);
    idx.write_buffer.active = false;
    try idx.write_buffer.flush(&database);
    try std.testing.expectEqual(base + 1, try countNames.run(&database));
    try std.testing.expect((try database.getNameByNamehash(nh_b)) == null);
}

// Both of the following pinned nothing before: sabotaging either fix left the
// whole suite green, which is how the defects survived in the first place.

test "Transfer for an unknown tokenId records a repairable placeholder, not a nameless event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const Indexer = @import("indexer/indexer.zig").Indexer;
    var idx = try Indexer.init(allocator, threaded.io(), cfg, &database, null);
    defer idx.deinit();

    const hash_mod = @import("types/hash.zig");
    const Hash = hash_mod.Hash;
    const Address = @import("types/address.zig").Address;
    const abi = @import("indexer/abi.zig");
    const v1_names = @import("utils/v1_names.zig");

    // A registry of our own, not cfg.v2_contracts: both handlers key only off
    // `log.address`, and the configured registry is the zero address whenever the
    // deployment env is absent — which silently skipped this test.
    const eth_registry = try Address.fromHex("0x7777777777777777777777777777777777777777");

    // Canonical (low 32 version bits zero) so the repair's canonical-id lookup is exact.
    const tok: u256 = @as(u256, 0x5EED) << 32;
    const to = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var to_topic = Hash.zero;
    @memcpy(to_topic.bytes[12..32], &to.bytes);

    // TransferSingle(operator, from, to, id, value) — arriving BEFORE the name is
    // known (a reorg, a backfill gap, or an orphaned transfer).
    var topics = [_]Hash{ abi.EventSignatures.transfer_single_hash, Hash.zero, Hash.zero, to_topic };
    var data = [_]u8{0} ** 64;
    std.mem.writeInt(u256, data[0..32], tok, .big);
    std.mem.writeInt(u256, data[32..64], 1, .big);
    try Indexer.handleTransfer(&idx, .v2, syntheticLog(eth_registry, topics[0..], data[0..], 300, 1_700_000_300));

    // The event must be addressable by its token id. Written with a null name and
    // null namehash it was unreachable from the name it belongs to and nothing
    // could ever repair it — a permanent hole in that name's history.
    const placeholder = try std.fmt.allocPrint(allocator, "tokenId:{d}", .{tok});
    {
        const evs = try database.getEventsByDomain(placeholder, 10);
        defer {
            for (evs) |*e| e.deinit(database.allocator);
            database.allocator.free(evs);
        }
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(models_mod.EventType.transfer, evs[0].event_type);
    }

    // Once the name is known, the existing placeholder ledger heals the row —
    // which is the whole reason the placeholder name is the right thing to write.
    const nh = try hash_mod.namehash(allocator, "xfer.eth");
    try idx.insertName(.{
        .name = "xfer.eth",
        .label = "xfer",
        .label_hash = v1_names.computeLabelHash("xfer"),
        .parent_name = "eth",
        .parent_namehash = idx.eth_namehash,
        .protocol = .v2,
        .registry = eth_registry,
        .owner = to,
        .registrant = to,
        .resolver = Address.zero,
        .token_id = tok,
        .canonical_id = tok,
        .token_version = 0,
        .namehash = nh,
        .expiry = 1_900_000_000,
        .registry_locked = false,
        .migrated = false,
        .created_block = 299,
        .created_at = 1_700_000_299,
        .registered_at = 1_700_000_299,
        .updated_block = 299,
        .updated_at = 1_700_000_299,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    try std.testing.expectEqual(@as(usize, 1), try database.repairPlaceholderEvents(.v2, 0, 1000));
    {
        const evs = try database.getEventsByDomain("xfer.eth", 10);
        defer {
            for (evs) |*e| e.deinit(database.allocator);
            database.allocator.free(evs);
        }
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expect(evs[0].namehash.?.eql(nh));
    }
}

test "TokenRegenerated re-keys approvals even when the name is not indexed yet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = @import("config.zig").Config.fromEnv(allocator) catch return;
    cfg.status_port = null;
    cfg.webhooks_enabled = false;
    defer cfg.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    const db_mod = @import("storage/database.zig");
    var database = try db_mod.Database.init(allocator, ":memory:");
    defer database.deinit();
    const Indexer = @import("indexer/indexer.zig").Indexer;
    var idx = try Indexer.init(allocator, threaded.io(), cfg, &database, null);
    defer idx.deinit();

    const hash_mod = @import("types/hash.zig");
    const Hash = hash_mod.Hash;
    const Address = @import("types/address.zig").Address;
    const abi = @import("indexer/abi.zig");

    // A registry of our own, not cfg.v2_contracts: both handlers key only off
    // `log.address`, and the configured registry is the zero address whenever the
    // deployment env is absent — which silently skipped this test.
    const eth_registry = try Address.fromHex("0x7777777777777777777777777777777777777777");

    const old_token_id: u256 = 900;
    const new_token_id: u256 = 901;
    const owner = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const operator = try Address.fromHex("0x3333333333333333333333333333333333333333");
    try database.insertApproval(.v2, old_token_id, owner, operator, 100, Hash.zero, eth_registry);

    // TokenRegenerated(oldTokenId, newTokenId), both indexed, for a token whose
    // name this indexer has never seen. Approvals are keyed by (token_id,
    // registry) — both of which this log supplies — so the re-key must happen
    // regardless. It used to sit inside the "namehash is known" branch, which
    // left the approval pointing at a token id the chain had already retired,
    // permanently: a later sighting re-keys the name row but never the approval.
    var old_topic = Hash.zero;
    std.mem.writeInt(u256, &old_topic.bytes, old_token_id, .big);
    var new_topic = Hash.zero;
    std.mem.writeInt(u256, &new_topic.bytes, new_token_id, .big);
    var topics = [_]Hash{ abi.EventSignatures.token_regenerated_hash, old_topic, new_topic };
    var empty: [0]u8 = .{};
    try Indexer.handleTokenRegenerated(&idx, .v2, syntheticLog(eth_registry, topics[0..], empty[0..], 400, 1_700_000_400));

    const Query = db_mod.Query;
    var q = try Query.init(&database, "SELECT token_id FROM approvals WHERE registry = ? AND protocol = ?");
    defer q.deinit();
    try q.bindAddress(eth_registry);
    try q.bindTextStatic("v2");
    try std.testing.expect(try q.step());
    try std.testing.expectEqualStrings("901", q.getTextSlice(0).?);
    try std.testing.expect(!try q.step());
}
