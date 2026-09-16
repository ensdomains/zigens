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

fn expectDns(a: std.mem.Allocator, wire: []const u8, want: []const u8) !void {
    const got = (try dns.decodeDNSNameToString(a, wire)) orelse return error.TestUnexpectedResult;
    defer a.free(got);
    try std.testing.expectEqualStrings(want, got);
}

// Pins the semantics the V2 resolver handlers rely on after the duplicate
// decoder was folded into utils/dns.zig: identical dotted-name output on valid
// (and tolerated-malformed) input, and null — never a decode error — on
// rejected input, which the call sites turn into warn/skip via `orelse`.
test "decodeDNSNameToString: DNS wire-format → dotted name; failures fold to null" {
    const a = std.testing.allocator;
    try expectDns(a, "\x03eth\x00", "eth");
    try expectDns(a, "\x05alice\x03eth\x00", "alice.eth");
    try expectDns(a, "\x03sub\x05alice\x03eth\x00", "sub.alice.eth");
    // A missing root terminator still decodes (the loop ends at data.len).
    try expectDns(a, "\x03eth", "eth");
    // Bytes after the root terminator are ignored, not an error.
    try expectDns(a, "\x03eth\x00junk", "eth");
    // Rejected inputs fold to null: empty, label running past the buffer,
    // and a bare root terminator (no labels).
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, ""));
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, "\x05ab"));
    try std.testing.expectEqual(@as(?[]const u8, null), try dns.decodeDNSNameToString(a, "\x00"));
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
