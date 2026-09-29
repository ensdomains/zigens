//! GraphQL conformance harness.
//!
//! Runs a fixed set of subgraph-shaped GraphQL operations against a deterministic
//! in-memory fixture through the REAL GraphQLHandler, and asserts each JSON
//! response matches a committed golden in tests/conformance/golden/<op>.json. This
//! turns "subgraph-compatible" from an ad-hoc claim into a byte-for-byte gate: any
//! change to a served response shape or value fails this lane with a readable diff.
//!
//! Determinism: the fixture seeds fixed timestamps/blocks and pins sync_state, and
//! the GraphQL read path performs no wall-clock reads — so every response is a pure
//! function of DB state. `_meta.block.number` = max(sync_state v1,v2); block hash and
//! timestamp are null by design.
//!
//! Modes (env vars):
//!   CONFORMANCE_UPDATE=1  — (re)write every golden/<op>.json from the actual output.
//!                           Review the diff, then commit. Use after changing an op or
//!                           an intentional behavior change.
//!   CONFORMANCE_PRINT=1   — dump each op's actual JSON to stderr (debugging).
//!   CONFORMANCE_LEAKCHECK=1 — run on testing.allocator (leak gate) instead of the
//!                           default arena, turning exercised resolver paths into a
//!                           leak check too.
//! id-parameterized ops use GraphQL variables so the query strings stay static.

const std = @import("std");
const zsys = @import("lib").zsys;
const testing = std.testing;
const helpers = @import("helpers");
const lib = @import("lib");

const models = lib.models;
const Address = lib.Address;
const Hash = lib.Hash;
const Database = lib.Database;
const GraphQLHandler = lib.api.handler.GraphQLHandler;
const resolvers = lib.storage.resolvers;

const FIXED_TS: i64 = 1700000000;
const FIXED_BLOCK: u64 = 100;
const GOLDEN_DIR = "tests/conformance/golden";

fn seedName(
    db: *Database,
    a: std.mem.Allocator,
    name: []const u8,
    label: []const u8,
    parent: []const u8,
    owner: Address,
    resolver: Address,
    token_id: u256,
    expiry: u64,
    is_wrapped: bool,
    fuses: ?[]const u8,
) !Hash {
    const nh = try lib.namehash(a, name);
    try db.insertName(models.Name{
        .protocol = .v2,
        .name = name,
        .namehash = nh,
        .label = label,
        .label_hash = try lib.labelhash(a, label),
        .parent_name = parent,
        .parent_namehash = try lib.namehash(a, parent),
        .registry = Address.zero,
        .owner = owner,
        .registrant = owner,
        .resolver = resolver,
        .token_id = token_id,
        .canonical_id = token_id,
        .token_version = 1,
        .expiry = expiry,
        .registry_locked = false,
        .migrated = false,
        .created_block = FIXED_BLOCK,
        .created_at = FIXED_TS,
        .registered_at = FIXED_TS,
        .updated_block = FIXED_BLOCK,
        .updated_at = FIXED_TS,
        .is_wrapped = is_wrapped,
        .wrapper_fuses = fuses,
        .wrapper_expiry = if (is_wrapped) 2000000000 else null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    return nh;
}

fn seedFixture(db: *Database, a: std.mem.Allocator) !void {
    // Pin the indexed head so _meta is deterministic.
    try db.setSyncState(.v1, 0);
    try db.setSyncState(.v2, 12345);

    const owner1 = helpers.TEST_OWNER_1;
    const owner2 = helpers.TEST_OWNER_2;
    const resolver = helpers.TEST_RESOLVER;
    const tx = Hash{ .bytes = [_]u8{0xAA} ** 32 };

    // alice.eth — plain 2LD with a resolver + addr + text records.
    const alice = try seedName(db, a, "alice.eth", "alice", "eth", owner1, resolver, 0xA11CE, 2000000000, false, null);
    // sub.alice.eth — subname with its own resolver; wrapped, to exercise the
    // subdomain (SHORT-select) wrapper-field path.
    _ = try seedName(db, a, "sub.alice.eth", "sub", "alice.eth", owner1, resolver, 0x5, 0, true, "65536");
    // bob.eth — wrapped name (different owner).
    const bob = try seedName(db, a, "bob.eth", "bob", "eth", owner2, Address.zero, 0xB0B, 2000000000, true, "65536");
    // expired.eth — 2LD with a long-past expiry, to exercise expiryDate/gracePeriodEnd.
    const expired = try seedName(db, a, "expired.eth", "expired", "eth", owner2, resolver, 0xE, 1600000000, false, null);

    // Resolver entity + records for alice.
    var resolver_hex: [42]u8 = undefined;
    const resolver_hexs = resolver.toHexBuf(&resolver_hex);
    var alice_hex: [66]u8 = undefined;
    const alice_hexs = alice.toHexBuf(&alice_hex);
    try resolvers.upsertResolverEntity(db, .v2, resolver_hexs, alice_hexs, "alice.eth", FIXED_BLOCK, FIXED_TS);
    try resolvers.storeResolverAddress(db, alice, resolver, 60, "0x1234567890abcdef1234567890abcdef12345678", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverText(db, alice, resolver, "avatar", "https://example.com/a.png", .v2, FIXED_BLOCK, tx, FIXED_TS);

    // V2 account observations for the name owners (mirrors the indexer's
    // recordAccountObservation; storage insertName alone never touches `accounts`).
    var o1_buf: [42]u8 = undefined;
    var o2_buf: [42]u8 = undefined;
    try db.upsertAccount(.v2, owner1.toHexBuf(&o1_buf), FIXED_BLOCK, FIXED_TS);
    try db.upsertAccount(.v2, owner2.toHexBuf(&o2_buf), FIXED_BLOCK, FIXED_TS);

    // V2 event lifecycle for alice.eth, feeding domain(id:, atBlock:) reconstruction:
    // register(200) -> resolver set(210) -> addr record(220) -> transfer(230). Distinct
    // log_index per event — the events UNIQUE is (protocol, tx_hash, log_index).
    const ab_registry = try Address.fromHex("0x7777777777777777777777777777777777777777");
    const AbEv = struct { et: models.EventType, blk: u64, li: u32, contract: Address, data: []const u8 };
    const ab_events = [_]AbEv{
        .{ .et = .label_registered, .blk = 200, .li = 9000, .contract = ab_registry, .data = "{\"name\":\"alice.eth\",\"tokenId\":4242,\"owner\":\"0x1111111111111111111111111111111111111111\",\"expiry\":1950000000,\"registry\":\"0x7777777777777777777777777777777777777777\"}" },
        .{ .et = .resolver_updated, .blk = 210, .li = 9001, .contract = ab_registry, .data = "{\"tokenId\":4242,\"resolver\":\"0xcccccccccccccccccccccccccccccccccccccccc\"}" },
        .{ .et = .address_changed, .blk = 220, .li = 9002, .contract = resolver, .data = "{\"resolver\":\"0xcccccccccccccccccccccccccccccccccccccccc\",\"coinType\":60,\"address\":\"0xdddddddddddddddddddddddddddddddddddddddd\"}" },
        .{ .et = .transfer, .blk = 230, .li = 9003, .contract = ab_registry, .data = "{\"to\":\"0x2222222222222222222222222222222222222222\"}" },
    };
    for (ab_events) |e| {
        try db.insertEvent(.{
            .event_type = e.et,
            .protocol = .v2,
            .block_number = e.blk,
            .tx_hash = Hash.zero,
            .log_index = e.li,
            .contract_address = e.contract,
            .name = "alice.eth",
            .namehash = alice,
            .data = e.data,
            .timestamp = FIXED_TS,
        });
    }

    // Primary (reverse) name: owner1 -> alice.eth. primaryName resolves in two hops —
    // reverse_records[owner1] -> namehash, then resolver_names[namehash] -> the name()
    // record. We use alice's namehash as the reverse target and store its name() record
    // so the full path is exercised (getLatestNameByNamehash reads resolver_names).
    try db.upsertReverseRecord(.v2, owner1, alice, FIXED_BLOCK, tx, 0, FIXED_TS);
    try resolvers.storeResolverName(db, alice, resolver, "alice.eth", .v2, FIXED_BLOCK, tx, FIXED_TS);

    // EAC role assignment on alice's resolver, so roles(resource:) + permissions
    // decoding are exercised. resource/bitmap mirror a real emitted pair.
    try db.upsertEACRole(
        .v2,
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        owner1,
        "0x0000000000000000000000000000000000000000000000000000000001000000",
        FIXED_BLOCK,
        tx,
        0,
        resolver,
        FIXED_TS,
    );
    // Same resource on a SECOND contract: locks the cross-contract semantics —
    // the unscoped query returns both rows (with contractAddress telling them
    // apart) and `contract:` isolates one. This is the shape that made a
    // ROOT-resource role holder from another contract look like a mystery
    // address on a name's roles page.
    const other_contract = Address{ .bytes = [_]u8{0x77} ** 20 };
    try db.upsertEACRole(
        .v2,
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        owner2,
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        FIXED_BLOCK,
        tx,
        1,
        other_contract,
        FIXED_TS,
    );

    // Versioned registry resources: `versioned.eth` on registry 0x7777 was
    // registered (owner1 granted at EAC version 0), unregistered and
    // re-registered (owner2 granted at version 1). The contract now resolves
    // version 1 only, so the version-0 grant must drop out of every listing
    // that does not name a resource, while the events keep both verbatim.
    const versioned_canonical: u256 = 0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000;
    const versioned = try lib.namehash(a, "versioned.eth");
    try db.insertName(models.Name{
        .protocol = .v2,
        .name = "versioned.eth",
        .namehash = versioned,
        .label = "versioned",
        .label_hash = try lib.labelhash(a, "versioned"),
        .parent_name = "eth",
        .parent_namehash = try lib.namehash(a, "eth"),
        .registry = other_contract,
        .owner = owner2,
        .registrant = owner2,
        .resolver = Address.zero,
        .token_id = versioned_canonical | 1,
        .canonical_id = versioned_canonical,
        .token_version = 1,
        .expiry = 2000000000,
        .registry_locked = false,
        .migrated = false,
        .created_block = FIXED_BLOCK,
        .created_at = FIXED_TS,
        .registered_at = FIXED_TS,
        .updated_block = FIXED_BLOCK,
        .updated_at = FIXED_TS,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    });
    const versioned_v0 = "0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000";
    const versioned_v1 = "0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001";
    const root_resource = "0x0000000000000000000000000000000000000000000000000000000000000000";
    try db.upsertEACRole(.v2, versioned_v0, owner1, "0x0000000000000000000000000000000000000000000000000000000000000111", 300, tx, 2, other_contract, FIXED_TS);
    try db.upsertEACRole(.v2, versioned_v1, owner2, "0x0000000000000000000000000000000000000000000000000000000000000111", 320, tx, 3, other_contract, FIXED_TS);
    try db.upsertEACRole(.v2, root_resource, owner1, "0x0000000000000000000000000000000000000000000000000000000000010001", 290, tx, 4, other_contract, FIXED_TS);
    const RoleEv = struct { blk: u64, li: u32, data: []const u8 };
    const role_events = [_]RoleEv{
        .{ .blk = 290, .li = 9100, .data = "{\"resource\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"account\":\"0x1111111111111111111111111111111111111111\",\"oldRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"newRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000010001\"}" },
        .{ .blk = 300, .li = 9101, .data = "{\"resource\":\"0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000\",\"account\":\"0x1111111111111111111111111111111111111111\",\"oldRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"newRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000111\"}" },
        .{ .blk = 320, .li = 9102, .data = "{\"resource\":\"0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001\",\"account\":\"0x2222222222222222222222222222222222222222\",\"oldRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000000\",\"newRoleBitmap\":\"0x0000000000000000000000000000000000000000000000000000000000000111\"}" },
    };
    for (role_events) |e| {
        try db.insertEvent(.{
            .event_type = .eac_roles_changed,
            .protocol = .v2,
            .block_number = e.blk,
            .tx_hash = Hash.zero,
            .log_index = e.li,
            .contract_address = other_contract,
            .name = if (e.blk == 290) null else "versioned.eth",
            .namehash = if (e.blk == 290) null else versioned,
            .data = e.data,
            .timestamp = FIXED_TS,
        });
    }

    // Registration rows: the `registrations` query reads a dedicated table that
    // insertName does not touch, so seed the .eth 2LDs (subnames are not registrations).
    try db.insertRegistration(.v2, alice, "alice", "eth", owner1, FIXED_TS, 2000000000, FIXED_BLOCK, tx, 0, .name_registered);
    try db.insertRegistration(.v2, bob, "bob", "eth", owner2, FIXED_TS, 2000000000, FIXED_BLOCK, tx, 1, .name_registered);
    try db.insertRegistration(.v2, expired, "expired", "eth", owner2, FIXED_TS, 1600000000, FIXED_BLOCK, tx, 2, .name_registered);

    // Finality positions (Task 09): seed safe/finalized so the _finality op is deterministic.
    // safe(12340) is below the indexed head (12345) → isStale=false.
    const safe_hash = Hash{ .bytes = [_]u8{0xf5} ** 32 };
    const fin_hash = Hash{ .bytes = [_]u8{0xf9} ** 32 };
    try db.setFinality(db.chain_id, .safe, 12340, safe_hash, FIXED_TS);
    try db.setFinality(db.chain_id, .finalized, 12300, fin_hash, FIXED_TS);
}

const Op = struct {
    name: []const u8,
    query: []const u8,
    vars: ?[]const u8 = null, // JSON object string, or null
};

const Mode = enum { compare, update, print };

fn checkOp(a: std.mem.Allocator, handler: *GraphQLHandler, db: *Database, op: Op, mode: Mode) !void {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |p| p.deinit();
    const vars_value: ?std.json.Value = if (op.vars) |vj| blk: {
        parsed = try std.json.parseFromSlice(std.json.Value, a, vj, .{});
        break :blk parsed.?.value;
    } else null;

    const result = try handler.handleQuery(db, op.query, vars_value, null, false);
    defer a.free(result);

    if (mode == .print) {
        std.debug.print("=== {s} ===\n{s}\n", .{ op.name, result });
        return;
    }

    const path = try std.fmt.allocPrint(a, GOLDEN_DIR ++ "/{s}.json", .{op.name});
    defer a.free(path);

    if (mode == .update) {
        zsys.makePath(GOLDEN_DIR) catch {};
        try zsys.writeFile(path, result);
        std.debug.print("updated {s}\n", .{path});
        return;
    }

    const golden = zsys.readFileAlloc(a, path, 1 << 20) catch |e| {
        std.debug.print("\nMISSING GOLDEN {s} ({}). Run: CONFORMANCE_UPDATE=1 zig build test-conformance\n", .{ path, e });
        return e;
    };
    defer a.free(golden);
    try compareGolden(op.name, golden, result);
}

/// The conformance comparator: a STRICT byte-for-byte compare with a readable diff on
/// mismatch. Extracted + named so the self-test below locks that a mutated response is
/// actually rejected — guarding against the comparison ever being weakened to a lenient
/// (substring / whitespace-normalized) match that would silently pass real divergences.
fn compareGolden(op_name: []const u8, golden: []const u8, result: []const u8) !void {
    testing.expectEqualStrings(golden, result) catch |e| {
        std.debug.print("\nCONFORMANCE MISMATCH [{s}]\n  golden: {s}\n  actual: {s}\n", .{ op_name, golden, result });
        return e;
    };
}

test "conformance comparator is strict: identical passes, a one-byte mutation fails" {
    const a = testing.allocator;
    const golden = "{\"data\":{\"domain\":{\"name\":\"alice.eth\"}}}";
    // Known-good: identical bytes pass.
    try compareGolden("selftest", golden, golden);
    // Mutated response: flip one byte — the SAME comparator checkOp uses must reject it,
    // so a golden/response divergence can never slip through as a silent pass.
    const mutated = try a.dupe(u8, golden);
    defer a.free(mutated);
    mutated[mutated.len - 3] +%= 1;
    try testing.expect(!std.mem.eql(u8, golden, mutated));
    try testing.expectError(error.TestExpectedEqual, compareGolden("selftest", golden, mutated));
}

test "conformance goldens" {
    const leakcheck = zsys.hasEnv("CONFORMANCE_LEAKCHECK");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = if (leakcheck) testing.allocator else arena.allocator();

    const db = try helpers.createTestDatabase(a);
    defer helpers.destroyTestDatabase(a, db);
    try seedFixture(db, a);

    var handler = try GraphQLHandler.init(a, 30, 100000, false);
    defer handler.deinit();

    const mode: Mode = if (zsys.hasEnv("CONFORMANCE_PRINT"))
        .print
    else if (zsys.hasEnv("CONFORMANCE_UPDATE"))
        .update
    else
        .compare;

    // Variable payloads (id/address) for parameterized ops.
    var alice_buf: [66]u8 = undefined;
    var bob_buf: [66]u8 = undefined;
    var exp_buf: [66]u8 = undefined;
    var owner_buf: [42]u8 = undefined;
    const alice_hex = (try lib.namehash(a, "alice.eth")).toHexBuf(&alice_buf);
    const bob_hex = (try lib.namehash(a, "bob.eth")).toHexBuf(&bob_buf);
    const exp_hex = (try lib.namehash(a, "expired.eth")).toHexBuf(&exp_buf);
    const owner_hex = helpers.TEST_OWNER_1.toHexBuf(&owner_buf);

    const alice_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{alice_hex});
    defer a.free(alice_vars);
    const bob_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{bob_hex});
    defer a.free(bob_vars);
    const exp_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{exp_hex});
    defer a.free(exp_vars);
    const owner_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{owner_hex});
    defer a.free(owner_vars);
    var resolver_buf: [42]u8 = undefined;
    const resolver_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{helpers.TEST_RESOLVER.toHexBuf(&resolver_buf)});
    defer a.free(resolver_vars);

    const ops = [_]Op{
        .{ .name = "meta", .query = "{ _meta { block { number hash } hasIndexingErrors } }" },
        .{ .name = "domains_ordered", .query = "{ domains(first: 10, orderBy: createdAt, orderDirection: asc) { id name owner { id } isWrapped protocol } }" },
        .{ .name = "domain_by_id", .query = "query($id:String!){ domain(id:$id){ id name labelName labelhash owner { id } registrant { id } resolver { id address } isWrapped isReachable protocol subdomainCount expiryDate tokenId } }", .vars = alice_vars },
        .{ .name = "resolver_records", .query = "query($id:String!){ domain(id:$id){ resolver { id address addr coinTypes texts } } }", .vars = alice_vars },
        .{ .name = "subdomains", .query = "query($id:String!){ domain(id:$id){ subdomainCount subdomains { id name owner { id } isWrapped fuses } } }", .vars = alice_vars },
        .{ .name = "wrapped_domain", .query = "query($id:String!){ domain(id:$id){ id isWrapped fuses wrapperExpiry } }", .vars = bob_vars },
        .{ .name = "account_domains", .query = "query($id:String!){ account(id:$id){ id domains { id name } seenV2 } }", .vars = owner_vars },
        // --- broadened coverage ---
        .{ .name = "primary_name", .query = "query($id:String!){ account(id:$id){ id primaryName } }", .vars = owner_vars },
        .{ .name = "expired_domain", .query = "query($id:String!){ domain(id:$id){ name expiryDate gracePeriodEnd isReachable } }", .vars = exp_vars },
        .{ .name = "eac_roles", .query = "{ roles(resource: \"0x0000000000000000000000000000000000000000000000000000000000000001\") { id resource account contractAddress roleBitmap permissions blockNumber } }" },
        // `contract:` scopes a shared resource to one emitting contract — the
        // unscoped op above returns rows from BOTH fixture contracts.
        .{ .name = "eac_roles_scoped", .query = "{ roles(resource: \"0x0000000000000000000000000000000000000000000000000000000000000001\", contract: \"0x7777777777777777777777777777777777777777\") { account contractAddress roleBitmap } }" },
        // The SAME resource queried by its zero-TRIMMED spelling (what clients
        // get back from Domain.tokenId) must return identical rows — locks the
        // ResourceForms widening for leading-zero resources.
        .{ .name = "eac_roles_trimmed_resource", .query = "{ roles(resource: \"0x1\") { id resource account contractAddress roleBitmap permissions blockNumber } }" },
        // --- verbatim registry resources (EAC version bits) ---
        // Contract listing hides the superseded version-0 grant of versioned.eth
        // and keeps ROOT; the current grant attributes to the name by canonical prefix.
        .{ .name = "eac_roles_registry_current", .query = "{ roles(contract: \"0x7777777777777777777777777777777777777777\") { resource account name roleBitmap } roleConnection(contract: \"0x7777777777777777777777777777777777777777\", first: 10) { totalCount edges { node { resource account name } } } }" },
        // Naming the superseded resource explicitly still returns it (history is kept).
        .{ .name = "eac_roles_superseded_explicit", .query = "{ roles(resource: \"0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000000\") { resource account name } }" },
        // EventFilter.resource + asEACRolesChanged: exact match on the emitted resource,
        // any hex spelling (ROOT as "0x0"), scoped to the contract.
        .{ .name = "events_resource_versioned", .query = "{ events(where: { resource: \"0x53f632a801578489983227b234817273b09ffad9c79c50366f6ff4d600000001\", contractAddress: \"0x7777777777777777777777777777777777777777\" }) { type blockNumber domain { name } asEACRolesChanged { resource account oldRoleBitmap newRoleBitmap } asTransfer { to } } }" },
        .{ .name = "events_resource_root_trimmed", .query = "{ events(where: { resource: \"0x0\", contractAddress: \"0x7777777777777777777777777777777777777777\" }) { type blockNumber asEACRolesChanged { resource account newRoleBitmap } } }" },
        // Per-type list in the same family as labelRegistereds/expiryUpdateds.
        .{ .name = "events_eac_roles_changeds", .query = "{ eacRolesChangeds(first: 5, where: { contractAddress: \"0x7777777777777777777777777777777777777777\" }, orderBy: blockNumber, orderDirection: asc) { blockNumber asEACRolesChanged { resource account } } }" },
        // --- introspection honours the selection set (was: canned whole document) ---
        .{ .name = "introspection_query_type_fields", .query = "{ __schema { queryType { name fields { name } } mutationType { name } } }" },
        .{ .name = "introspection_aliased_type", .query = "{ filter: __type(name: \"EventFilter\") { kind name inputFields { name type { kind name ofType { kind name } } } } __typename }" },
        .{ .name = "introspection_fragments", .query = "query IntrospectionQuery { __schema { types { ...T } } } fragment T on __Type { kind name }" },
        // events(skip:) pages the plain list (was silently ignored).
        .{ .name = "events_skip", .query = "{ events(first: 1, skip: 1, where: { type: \"EACRolesChanged\", contractAddress: \"0x7777777777777777777777777777777777777777\" }, orderBy: blockNumber, orderDirection: asc) { blockNumber asEACRolesChanged { account } } }" },
        .{ .name = "pagination_skip", .query = "{ domains(first: 2, skip: 1, orderBy: createdAt, orderDirection: asc) { id name } }" },
        .{ .name = "domain_connection", .query = "{ domainConnection(first: 2, orderBy: createdAt, orderDirection: asc) { edges { cursor node { id name } } pageInfo { hasNextPage hasPreviousPage startCursor endCursor } } }" },
        // --- where-filter matrix (deterministic order via orderBy createdAt asc, namehash tie-break) ---
        .{ .name = "filter_owner", .query = "{ domains(where:{owner:\"0x1111111111111111111111111111111111111111\"}, orderBy:createdAt, orderDirection:asc){ id name } }" },
        .{ .name = "filter_name_exact", .query = "{ domains(where:{name:\"bob.eth\"}){ id name } }" },
        .{ .name = "filter_name_contains", .query = "{ domains(where:{name_contains:\"alice\"}, orderBy:createdAt, orderDirection:asc){ id name } }" },
        .{ .name = "filter_name_ends_with", .query = "{ domains(where:{name_ends_with:\"alice.eth\"}, orderBy:createdAt, orderDirection:asc){ id name } }" },
        .{ .name = "filter_name_in", .query = "{ domains(where:{name_in:[\"alice.eth\",\"bob.eth\"]}, orderBy:createdAt, orderDirection:asc){ id name } }" },
        .{ .name = "filter_label_name", .query = "{ domains(where:{labelName:\"sub\"}){ id name } }" },
        .{ .name = "filter_expiry_gt", .query = "{ domains(where:{expiryDate_gt:1900000000}, orderBy:createdAt, orderDirection:asc){ id name expiryDate } }" },
        .{ .name = "filter_owner_and_ends_with", .query = "{ domains(where:{owner:\"0x2222222222222222222222222222222222222222\", name_ends_with:\".eth\"}, orderBy:createdAt, orderDirection:asc){ id name } }" },
        .{ .name = "filter_has_subdomains", .query = "{ domains(where:{hasSubdomains:true}){ id name } }" },
        // --- accounts list filters (AccountFilter: id/id_in/seenV1/seenV2) ---
        .{ .name = "accounts_seenv2", .query = "{ accounts(where:{seenV2:true}, orderBy:id, orderDirection:asc){ id seenV1 seenV2 } }" },
        .{ .name = "accounts_by_id", .query = "{ accounts(where:{id:\"0x1111111111111111111111111111111111111111\"}){ id primaryName } }" },
        .{ .name = "accounts_id_in", .query = "{ accounts(where:{id_in:[\"0x1111111111111111111111111111111111111111\",\"0x2222222222222222222222222222222222222222\"]}, orderBy:id, orderDirection:asc){ id } }" },
        // --- registrations list filters (RegistrationFilter: registrant/registrant_in/expiryDate_*/protocol) ---
        .{ .name = "registrations_all", .query = "{ registrations(first:10, orderBy:name, orderDirection:asc){ id name registrant { id } registrationDate expiryDate protocol } }" },
        .{ .name = "registrations_by_registrant", .query = "{ registrations(where:{registrant:\"0x2222222222222222222222222222222222222222\"}, orderBy:name, orderDirection:asc){ id name } }" },
        .{ .name = "registrations_expiry_gt", .query = "{ registrations(where:{expiryDate_gt:1900000000}, orderBy:name, orderDirection:asc){ id name expiryDate } }" },
        // Locks the page-batched nested path (domain rows + resolver texts served
        // via the request loader): alice's resolver has a seeded avatar record, so
        // this golden pins real values flowing through the batch, not just nulls.
        .{ .name = "registrations_domain_resolver_texts", .query = "{ registrations(first:10, orderBy:name, orderDirection:asc){ name domain { name resolver { address avatar: text(key:\"avatar\") missing: text(key:\"com.twitter\") } } } }" },
        // Locks the page-batched accounts→domains path (windowed per-owner
        // query + primed resolver records) against the per-account point-query
        // semantics it must reproduce exactly.
        .{ .name = "accounts_domains_batched", .query = "{ accounts(orderBy: id, orderDirection: asc, first: 10){ id domains { name expiryDate resolver { address avatar: text(key:\"avatar\") } } } }" },
        // Locks the batched `texts` key-LIST field on both primed list paths
        // (domains + registrations→domain): alice = ["avatar"], others empty.
        .{ .name = "domains_resolver_texts_list", .query = "{ domains(where:{name_in:[\"alice.eth\",\"bob.eth\"]}, orderBy:name, orderDirection:asc){ name resolver { texts } } }" },
        .{ .name = "registrations_domain_texts_list", .query = "{ registrations(first:10, orderBy:name, orderDirection:asc){ name domain { resolver { texts } } } }" },
        // Locks the batched `coinTypes` scalar-LIST on the primed domains list
        // (alice = ["60"]; bob has no resolver → null) against the point-query
        // semantics it must reproduce exactly.
        .{ .name = "domains_resolver_cointypes_list", .query = "{ domains(where:{name_in:[\"alice.eth\",\"bob.eth\"]}, orderBy:name, orderDirection:asc){ name resolver { coinTypes } } }" },
        // Locks the page-batched events→domain path (one IN-list domains query
        // + primed resolver records instead of a point query per event row).
        // All four seeded events share alice's namehash, so real domain rows
        // and record values flow through the batch, not just nulls.
        .{ .name = "events_domain_batched", .query = "{ events(first:10, orderBy:blockNumber, orderDirection:asc){ type blockNumber domain { name resolver { texts coinTypes } } } }" },
        // Locks the primed top-level resolvers list (addr/texts/coinTypes
        // served from the page batch, not per-row point queries).
        .{ .name = "resolvers_list_records", .query = "{ resolvers(first:10, orderBy:address, orderDirection:asc){ id address addr texts coinTypes } }" },
        // --- finality signalling (Task 09; _finality is additive, subgraph _meta unchanged) ---
        .{ .name = "finality", .query = "{ _finality { head { number } safe { number hash } finalized { number } isStale } }" },
        // --- coverage declaration (additive; lastSyncedAt is wall-clock so not selected) ---
        .{ .name = "coverage", .query = "{ _coverage { chainId stale protocols { protocol indexedHead } } }" },
        // --- error-shape ops: lock the GraphQL error envelope for cases that DO error ---
        .{ .name = "err_syntax", .query = "{ domains( }" },
        .{ .name = "err_missing_required_arg", .query = "{ domain { id } }" },
        .{ .name = "err_unknown_argument", .query = "{ domains(bogusArg: 1) { id } }" },
        .{ .name = "err_unknown_where_field", .query = "{ domains(where: {totallyBogus: 1}) { id } }" },
        .{ .name = "err_unknown_query", .query = "{ notARealQueryField { id } }" },
        // Unknown selection fields, and unknown arguments below the root, used to
        // resolve to null or be silently dropped; they now fail validation.
        .{ .name = "err_unknown_field", .query = "{ domains(first:1){ notARealField } }" },
        .{ .name = "err_unknown_nested_field", .query = "{ domains(first:1){ owner { notARealField } } }" },
        .{ .name = "err_unknown_fragment_field", .query = "query Q { domains(first:1){ ...F } } fragment F on Domain { notARealField }" },
        .{ .name = "err_unknown_root_fragment_field", .query = "query Q { ...Root } fragment Root on Query { domains(first:1){ notARealField } }" },
        .{ .name = "err_unknown_nested_argument", .query = "{ domains(first:1){ subdomains(bogus: 1) { id } } }" },
        .{ .name = "err_unknown_nested_where_field", .query = "{ domains(first:1){ events(where: {bogus: 1}) { id } } }" },
        .{ .name = "err_fragment_wrong_type", .query = "{ domains(first:1){ ... on Account { id } } }" },
        // __typename, aliases, named and inline fragments (spliced in, not
        // resolved as a field named after the type), and root-level fragments.
        .{ .name = "ok_typename_and_fragments", .query = "query Q { domains(first:1){ __typename n: name ...F ... on Domain { labelName } } } fragment F on Domain { id }" },
        .{ .name = "ok_root_fragment", .query = "query Q { ...Root } fragment Root on Query { domains(first:1){ name } }" },
        // Served fields that were missing from the schema, now declared: they must
        // keep answering rather than become validation errors.
        .{ .name = "ok_declared_domain_fields", .query = "query($id:String!){ domain(id:$id){ namehash domain { name } subdomainConnection { totalCount pageInfo { hasNextPage } edges { node { name } } } eventsConnection(first: 2) { totalCount edges { node { type } } } } }", .vars = alice_vars },
        .{ .name = "ok_declared_registration_fields", .query = "{ registrations(first:1, orderBy: registrationDate, orderDirection: asc){ name block blockNumber timestamp registrationDate } }" },
        .{ .name = "ok_declared_resolver_detail_fields", .query = "query($id:String!){ resolver(id:$id){ address recordModel domain { name } texts coinTypes addr text(key: \"avatar\") } }", .vars = resolver_vars },
        // An invalid orderBy enum is ignored (default order): an intentional
        // leniency, locked so it does not change silently.
        .{ .name = "lenient_invalid_orderby", .query = "{ domains(orderBy: notARealField){ id } }" },
        // An empty selection set is spec-invalid but accepted; the fast path must
        // emit the namehash id like every other Domain serialization.
        .{ .name = "lenient_empty_selection", .query = "query($id:String!){ domain(id:$id) }", .vars = alice_vars },
        // --- atBlock time travel (V2 event-log reconstruction; fixture lifecycle at
        //     blocks 200/210/220/230, sync head 12345) ---
        .{ .name = "atblock_mid", .query = "query($id:String!){ domain(id:$id, atBlock: 215){ id name owner { id } resolver { address addr } tokenId } }", .vars = alice_vars },
        .{ .name = "atblock_late", .query = "query($id:String!){ domain(id:$id, atBlock: 235){ id owner { id } resolver { addr text(key:\"avatar\") } } }", .vars = alice_vars },
        .{ .name = "atblock_prereg", .query = "query($id:String!){ domain(id:$id, atBlock: 150){ id name } }", .vars = alice_vars },
        .{ .name = "atblock_future", .query = "query($id:String!){ domain(id:$id, atBlock: 999999999){ id name } }", .vars = alice_vars },
        // --- history surfaces over the events log ---
        .{ .name = "history_name", .query = "query($id:String!){ events(where:{namehash:$id}, orderBy: blockNumber, orderDirection: asc){ type blockNumber } }", .vars = alice_vars },
        .{ .name = "history_address", .query = "{ events(where:{involved:\"0x2222222222222222222222222222222222222222\"}, orderBy: blockNumber, orderDirection: asc){ type blockNumber } }" },
        // Two aliases of the same list re-run the batch record prefetch over the same
        // (resolver, namehash) pairs; locks output and, under CONFORMANCE_LEAKCHECK,
        // the repeat-populate value replacement in loaders.zig. name_in (not name:)
        // so the general list path runs — the name-exact fast path skips the prefetch.
        .{ .name = "aliased_batch_records", .query = "{ a: domains(where:{name_in:[\"alice.eth\"]}){ resolver { addr text(key:\"avatar\") } } b: domains(where:{name_in:[\"alice.eth\"]}){ resolver { addr text(key:\"avatar\") } } }" },
    };

    for (ops) |op| try checkOp(a, &handler, db, op, mode);
}

// Task 06 acceptance: with live resolution ON, a record the index does NOT carry (an
// addr MISS on a name that only has a resolver pointer) resolves via the Universal
// Resolver fallback; with it OFF the same query returns null. The UR eth_call is served
// from a PRE-SEEDED resolution_cache row (a deliberately-undefined rpc client would crash
// if the fallback wrongly hit the network), so this runs fully offline yet exercises the
// entire wiring: handler -> executor context.resolve -> nested propagation ->
// resolverAddrHandler -> liveRecordFallback -> universal.resolve -> cache hit -> JSON.
test "task06: indexed-miss addr resolves via Universal Resolver only when live is ON" {
    const a = testing.allocator;
    const cache = lib.resolve.cache;
    const uni = lib.resolve.universal;

    const db = try helpers.createTestDatabase(a);
    defer helpers.destroyTestDatabase(a, db);

    // A name with a resolver set but NO indexed addr record — the exact MISS the fallback
    // is meant to cover (e.g. a wildcard/uncached record).
    const owner = helpers.TEST_OWNER_1;
    const resolver = helpers.TEST_RESOLVER;
    _ = try seedName(db, a, "wildcard.eth", "wildcard", "eth", owner, resolver, 0x1, 2000000000, false, null);
    const node = try lib.namehash(a, "wildcard.eth");

    const ur_addr = Address{ .bytes = [_]u8{0xee} ** 20 };
    const block_num: u64 = 500;
    const block_hash = Hash{ .bytes = [_]u8{0xcd} ** 32 };
    const now: i64 = 1_700_000_000;

    // Pre-seed the resolution_cache with a canned UR (bytes result, address) answer for
    // addr(node): result = a 32-byte word holding 0x22*20. Key matches universal.resolve.
    const rec: uni.Record = .addr;
    const inner = try uni.encodeInner(a, node, rec);
    defer a.free(inner);
    const calldata = try uni.encodeResolveCall(a, "wildcard.eth", inner);
    defer a.free(calldata);
    const selkey = try rec.cacheKey(a);
    defer a.free(selkey);
    var blob: [128]u8 = [_]u8{0} ** 128;
    blob[31] = 0x40;
    @memset(blob[44..64], 0x11);
    blob[95] = 32;
    @memset(blob[108..128], 0x22);
    try cache.put(db, .{
        .chain_id = 1,
        .target = ur_addr,
        .selector_key = selkey,
        .arg_hash = cache.argHash(calldata),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    }, .success, &blob, .resolved_live, now);

    var resolver_client = lib.resolve.client.Resolver.init(@as(*lib.rpc.client.Client, undefined), db, 1, 300);
    var live = uni.LiveContext{ .resolver = &resolver_client, .ur_address = ur_addr, .block_num = block_num, .block_hash = block_hash, .now = now };

    var handler = try GraphQLHandler.init(a, 30, 100000, false);
    defer handler.deinit();

    var nh_buf: [66]u8 = undefined;
    const nh_hex = node.toHexBuf(&nh_buf);
    const vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{nh_hex});
    defer a.free(vars);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, vars, .{});
    defer parsed.deinit();
    const query = "query($id:String!){ domain(id:$id){ resolver { addr } } }";

    // Flag OFF (null resolve ctx): indexed miss -> addr is null.
    const off = try handler.handleQuery(db, query, parsed.value, null, false);
    defer a.free(off);
    try testing.expect(std.mem.indexOf(u8, off, "\"addr\":null") != null);

    // Flag ON (live ctx): the fallback resolves addr from the pre-seeded UR answer.
    const on = try handler.handleQueryWithResolve(db, query, parsed.value, null, false, @ptrCast(&live));
    defer a.free(on);
    try testing.expect(std.mem.indexOf(u8, on, "0x2222222222222222222222222222222222222222") != null);

    // GATE: a domain whose resolver IS fully indexed (known_resolvers) must NOT fall
    // back — its indexed miss is authoritative. A UR answer (0x33…) is pre-seeded for
    // this node too, so addr staying null with the flag ON proves the gate
    // short-circuits before the cache/UR; a gate regression would surface 0x3333….
    const known_res = Address{ .bytes = [_]u8{0x77} ** 20 };
    _ = try seedName(db, a, "gated.eth", "gated", "eth", owner, known_res, 0x2, 2000000000, false, null);
    const gated_node = try lib.namehash(a, "gated.eth");
    const known_hex = try known_res.toHex(a);
    defer a.free(known_hex);
    try db.registerResolver(.v2, known_hex, 100);

    const g_inner = try uni.encodeInner(a, gated_node, rec);
    defer a.free(g_inner);
    const g_calldata = try uni.encodeResolveCall(a, "gated.eth", g_inner);
    defer a.free(g_calldata);
    var g_blob: [128]u8 = [_]u8{0} ** 128;
    g_blob[31] = 0x40;
    @memset(g_blob[44..64], 0x11);
    g_blob[95] = 32;
    @memset(g_blob[108..128], 0x33);
    try cache.put(db, .{
        .chain_id = 1,
        .target = ur_addr,
        .selector_key = selkey,
        .arg_hash = cache.argHash(g_calldata),
        .block_dep_num = block_num,
        .block_dep_hash = block_hash,
    }, .success, &g_blob, .resolved_live, now);

    var gnh_buf: [66]u8 = undefined;
    const gnh_hex = gated_node.toHexBuf(&gnh_buf);
    const gvars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{gnh_hex});
    defer a.free(gvars);
    const gparsed = try std.json.parseFromSlice(std.json.Value, a, gvars, .{});
    defer gparsed.deinit();
    const gated_on = try handler.handleQueryWithResolve(db, query, gparsed.value, null, false, @ptrCast(&live));
    defer a.free(gated_on);
    try testing.expect(std.mem.indexOf(u8, gated_on, "\"addr\":null") != null);
    try testing.expect(std.mem.indexOf(u8, gated_on, "0x3333333333333333333333333333333333333333") == null);
}

// ============================================================================
// Record-model resolvers (contracts-v2 IRecordResolver) — own fixture so the
// main goldens above stay byte-identical.
// ============================================================================

const RECORD_RESOLVER = Address{ .bytes = [_]u8{0xDD} ** 20 };

/// carol.eth owns record 1; erin.eth shares it (linkToRecord); dave.eth has no
/// link and falls through to the resolver-wide default record 2 (node 0x0).
/// Record 1 carries avatar/url/ETH addr/contenthash/data; record 2 only a url.
/// One ResourceArgument ("avatar") with a ROLE_SET_TEXT grant so the API can
/// derive its kind.
fn seedRecordResolverFixture(db: *Database, a: std.mem.Allocator) !void {
    try db.setSyncState(.v1, 0);
    try db.setSyncState(.v2, 12345);
    const owner1 = helpers.TEST_OWNER_1;
    const owner2 = helpers.TEST_OWNER_2;
    const rec = RECORD_RESOLVER;
    const tx = Hash{ .bytes = [_]u8{0xAA} ** 32 };
    const record_model = lib.storage.resolver_records;

    const carol = try seedName(db, a, "carol.eth", "carol", "eth", owner1, rec, 0xCA401, 2000000000, false, null);
    const erin = try seedName(db, a, "erin.eth", "erin", "eth", owner1, rec, 0xE41, 2000000000, false, null);
    const dave = try seedName(db, a, "dave.eth", "dave", "eth", owner2, rec, 0xDA5E, 2000000000, false, null);

    var rec_hex: [42]u8 = undefined;
    const rec_hexs = rec.toHexBuf(&rec_hex);
    for ([_]struct { nh: Hash, name: []const u8 }{ .{ .nh = carol, .name = "carol.eth" }, .{ .nh = erin, .name = "erin.eth" }, .{ .nh = dave, .name = "dave.eth" } }) |n| {
        var nh_buf: [66]u8 = undefined;
        try resolvers.upsertResolverEntity(db, .v2, rec_hexs, n.nh.toHexBuf(&nh_buf), n.name, FIXED_BLOCK, FIXED_TS);
    }

    // ResolverCreated + the links the setters/linkToRecord emitted.
    try db.upsertResolverKind(.v2, rec, "record", FIXED_BLOCK, tx, 0, FIXED_TS);
    try db.upsertResolverLink(.v2, rec, carol, 1, "carol.eth", FIXED_BLOCK, tx, 1, FIXED_TS);
    try db.upsertResolverLink(.v2, rec, erin, 1, "erin.eth", FIXED_BLOCK + 1, tx, 2, FIXED_TS);
    try db.upsertResolverLink(.v2, rec, Hash.zero, 2, "", FIXED_BLOCK + 2, tx, 3, FIXED_TS);

    const rk1 = record_model.recordKey(1);
    const rk2 = record_model.recordKey(2);
    try resolvers.storeResolverText(db, rk1, rec, "avatar", "https://records.example/carol.png", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverText(db, rk1, rec, "url", "https://carol.example", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverAddress(db, rk1, rec, 60, "0xcafe000000000000000000000000000000000001", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverAddress(db, rk1, rec, 0, "0x00010203", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverContentHash(db, rk1, rec, "0xe30101701220aa", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try db.storeResolverData(rk1, rec, "blob", "0xdeadbeef", .v2, FIXED_BLOCK, tx, FIXED_TS);
    try resolvers.storeResolverText(db, rk2, rec, "url", "https://default.example", .v2, FIXED_BLOCK, tx, FIXED_TS);

    // grantSetterRoles(setText(_, "avatar", _), owner1): ResourceArgument + EACRolesChanged(ROLE_SET_TEXT).
    var resource: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("avatar", &resource, .{});
    var resource_buf: [66]u8 = undefined;
    const resource_hex = (Hash{ .bytes = resource }).toHexBuf(&resource_buf);
    try db.upsertNamedResource(.v2, rec, resource_hex, "argument", "avatar", -1, "", FIXED_BLOCK, tx, 4);
    try db.upsertEACRole(.v2, resource_hex, owner1, "0x10", FIXED_BLOCK, tx, 5, rec, FIXED_TS);
}

test "conformance goldens: record-model resolvers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try helpers.createTestDatabase(a);
    defer helpers.destroyTestDatabase(a, db);
    try seedRecordResolverFixture(db, a);
    var handler = try GraphQLHandler.init(a, 30, 100000, false);
    defer handler.deinit();
    const mode: Mode = if (zsys.hasEnv("CONFORMANCE_PRINT"))
        .print
    else if (zsys.hasEnv("CONFORMANCE_UPDATE"))
        .update
    else
        .compare;

    var carol_buf: [66]u8 = undefined;
    const carol_hex = (try lib.namehash(a, "carol.eth")).toHexBuf(&carol_buf);
    const carol_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{carol_hex});
    var rec_buf: [42]u8 = undefined;
    const rec_hex = RECORD_RESOLVER.toHexBuf(&rec_buf);
    const rec_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{rec_hex});
    const resolvers_query = try std.fmt.allocPrint(a, "{{ resolvers(where:{{address:\"{s}\"}}, orderBy:setBlock, orderDirection:asc){{ id address recordModel recordId texts coinTypes addr linkedNames {{ name recordId }} }} }}", .{rec_hex});

    const ops = [_]Op{
        // List path: the page-batched loaders must translate every pair through its
        // record (own / shared / default) and serve identical values to the point path.
        .{ .name = "record_resolver_domains", .query = "{ domains(where:{name_in:[\"carol.eth\",\"erin.eth\",\"dave.eth\"]}, orderBy:name, orderDirection:asc){ name resolver { address recordModel recordId texts coinTypes addr contentHash dataKeys data(key:\"blob\") avatar: text(key:\"avatar\") url: text(key:\"url\") linkedNames { name namehash recordId } } } }" },
        // Point path for the record owner.
        .{ .name = "record_resolver_domain_carol", .query = "query($id:String!){ domain(id:$id){ name resolver { recordId recordModel texts coinTypes addr contentHash data(key:\"blob\") linkedNames { name recordId } aliases { fromName } } } }", .vars = carol_vars },
        // Top-level resolvers list (primed per page) over the same resolver.
        .{ .name = "record_resolver_entities", .query = resolvers_query },
        // ResourceArgument surfaces as one namedResources entry per granted setter kind.
        .{ .name = "record_resolver_named_resources", .query = "query($id:String!){ resolver(id:$id){ namedResources { protocol resource recordKind recordKey coinType name } } }", .vars = rec_vars },
    };
    for (ops) |op| try checkOp(a, &handler, db, op, mode);
    std.debug.print("conformance (record resolvers): all tests passed\n", .{});
}

// ============================================================================
// Nested list pagination — own fixture, with more children than the nested
// default page, so the default, `first`, `skip` and variables are all
// observable. The main fixture's single-child parent cannot tell them apart.
// ============================================================================

const PAGER_OWNER = Address{ .bytes = [_]u8{0x33} ** 20 };

/// many.eth has 12 children c00..c11 (two over the default page of 10);
/// c00.many.eth has 3 children of its own. PAGER_OWNER owns all 16 names and
/// has 12 registrations.
fn seedNestedPaginationFixture(db: *Database, a: std.mem.Allocator) !void {
    try db.setSyncState(.v1, 0);
    try db.setSyncState(.v2, 12345);
    const tx = Hash{ .bytes = [_]u8{0xAA} ** 32 };
    const owner = PAGER_OWNER;
    const resolver = helpers.TEST_RESOLVER;

    _ = try seedName(db, a, "many.eth", "many", "eth", owner, resolver, 0x3000, 2000000000, false, null);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const label = try std.fmt.allocPrint(a, "c{d:0>2}", .{i});
        const name = try std.fmt.allocPrint(a, "{s}.many.eth", .{label});
        const nh = try seedName(db, a, name, label, "many.eth", owner, resolver, 0x3100 + i, 0, false, null);
        try db.insertRegistration(.v2, nh, label, "many.eth", owner, FIXED_TS + @as(i64, @intCast(i)), 2000000000, FIXED_BLOCK, tx, @intCast(i), .name_registered);
    }
    i = 0;
    while (i < 3) : (i += 1) {
        const label = try std.fmt.allocPrint(a, "g{d}", .{i});
        const name = try std.fmt.allocPrint(a, "{s}.c00.many.eth", .{label});
        _ = try seedName(db, a, name, label, "c00.many.eth", owner, resolver, 0x3200 + i, 0, false, null);
    }

    var owner_buf: [42]u8 = undefined;
    try db.upsertAccount(.v2, owner.toHexBuf(&owner_buf), FIXED_BLOCK, FIXED_TS);
}

test "conformance goldens: nested list pagination" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const db = try helpers.createTestDatabase(a);
    defer helpers.destroyTestDatabase(a, db);
    try seedNestedPaginationFixture(db, a);
    var handler = try GraphQLHandler.init(a, 30, 100000, false);
    defer handler.deinit();
    const mode: Mode = if (zsys.hasEnv("CONFORMANCE_PRINT"))
        .print
    else if (zsys.hasEnv("CONFORMANCE_UPDATE"))
        .update
    else
        .compare;

    var many_buf: [66]u8 = undefined;
    const many_hex = (try lib.namehash(a, "many.eth")).toHexBuf(&many_buf);
    const many_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{many_hex});
    const many_page_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"n\":2,\"s\":1}}", .{many_hex});
    var owner_buf: [42]u8 = undefined;
    const owner_hex = PAGER_OWNER.toHexBuf(&owner_buf);
    const owner_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{owner_hex});
    const owner_page_vars = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"n\":1}}", .{owner_hex});

    const ops = [_]Op{
        // No args: the declared default page of 10 out of 12 children.
        .{ .name = "nested_subdomains_default", .query = "query($id:String!){ domain(id:$id){ subdomainCount subdomains { name } } }", .vars = many_vars },
        .{ .name = "nested_subdomains_first_skip", .query = "query($id:String!){ domain(id:$id){ subdomains(first: 3, skip: 10) { name } } }", .vars = many_vars },
        // Nested arguments resolve variables like root arguments do.
        .{ .name = "nested_subdomains_variables", .query = "query($id:String!, $n:Int, $s:Int){ domain(id:$id){ subdomains(first: $n, skip: $s) { name } } }", .vars = many_page_vars },
        .{ .name = "nested_subdomains_undefined_variable", .query = "query($id:String!){ domain(id:$id){ subdomains(first: $missing) { name } } }", .vars = many_vars },
        // List path (page-batched): aliased siblings and differing args per level.
        .{ .name = "nested_subdomains_aliased", .query = "{ domains(where:{name:\"many.eth\"}){ a: subdomains(first: 2) { name } b: subdomains(first: 2, skip: 2) { name } } }" },
        .{ .name = "nested_subdomains_mixed_levels", .query = "{ domains(where:{name:\"many.eth\"}){ subdomains(first: 1) { name subdomains(first: 2) { name } } } }" },
        .{ .name = "nested_account_domains_default", .query = "query($id:String!){ account(id:$id){ domains { name } } }", .vars = owner_vars },
        .{ .name = "nested_account_domains_variables", .query = "query($id:String!, $n:Int){ account(id:$id){ domains(first: $n, skip: $n) { name } } }", .vars = owner_page_vars },
        .{ .name = "nested_account_registrations_default", .query = "query($id:String!){ account(id:$id){ registrations { name } } }", .vars = owner_vars },
        .{ .name = "nested_accounts_aliased", .query = "{ accounts { a: domains(first: 1) { name } b: domains(first: 1, skip: 1) { name } } }" },
        // Codegen reads the defaults from introspection, so they must be there.
        .{ .name = "nested_pagination_introspection", .query = "{ __type(name: \"Account\") { fields { name args { name defaultValue } } } }" },
    };
    for (ops) |op| try checkOp(a, &handler, db, op, mode);
    std.debug.print("conformance (nested pagination): all tests passed\n", .{});
}
