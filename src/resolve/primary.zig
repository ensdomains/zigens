//! Reverse-claim forward verification (ENSIP-3).
//!
//! A reverse record only *claims* that an address's primary name is some name;
//! that claim is authoritative only if the name's forward resolution points back
//! to the same address. This module performs that forward check with two pinned
//! reads — `registry.resolver(node)` then `resolver.addr(node)` — and compares
//! the result to the claiming address.
//!
//! It is deliberately fail-closed: the claimed name must be ENSIP-15 normalized
//! (else `.invalid_name`, so a confusable/spoofed name can never be stamped
//! verified), and any remaining ambiguity — no resolver or empty record
//! (`.not_found`), a revert or transport failure (`.unverified`) — never yields a
//! false `.verified`. The claimed value itself is never altered by this check;
//! callers use the verdict only to annotate provenance.

const std = @import("std");
const client = @import("client.zig");
const cache = @import("cache.zig");
const Resolver = client.Resolver;
const Address = @import("../types/address.zig").Address;
const hash_mod = @import("../types/hash.zig");
const Hash = hash_mod.Hash;
const ens_normalize = @import("../utils/ens_normalize.zig");

/// `resolver(bytes32)` on the ENS registry — selector keccak256("resolver(bytes32)")[0..4].
const sel_resolver = [4]u8{ 0x01, 0x78, 0xb8, 0xbf };
/// `addr(bytes32)` on a resolver — selector keccak256("addr(bytes32)")[0..4]. This is
/// the coin-type-60 (ETH) forward address, sufficient for the default primary tuple.
const sel_addr = [4]u8{ 0x3b, 0x3b, 0x57, 0xde };

/// Outcome of a forward check.
pub const Verdict = enum {
    /// The name resolves forward to the claiming address.
    verified,
    /// The name resolves forward to a *different* address.
    mismatch,
    /// The claimed name is not ENSIP-15 normalized (e.g. confusable/spoofed); never verified.
    invalid_name,
    /// No forward evidence exists: no resolver, or an empty/zero address record.
    not_found,
    /// The on-chain read could not be completed (revert or RPC error).
    unverified,
};

/// Return the ENSIP-15 normalized form of `name` (owned by `allocator`) IFF `name` is
/// already in normalized form, else null. A claimed primary name that is not already
/// normalized is a confusable/spoof and must never verify.
pub fn normalizedClaimOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (name.len == 0) return null; // an empty name is not a verifiable claim
    var res = ens_normalize.normalizeName(allocator, name);
    defer res.deinit(allocator);
    const norm = res.normalized orelse return null;
    if (!res.is_valid or !std.mem.eql(u8, norm, name)) return null;
    return try allocator.dupe(u8, norm);
}

/// Build calldata for a `<selector>(bytes32 node)` call: selector ++ 32-byte node.
fn buildNodeCall(selector: [4]u8, node: Hash) [36]u8 {
    var out: [36]u8 = undefined;
    @memcpy(out[0..4], &selector);
    @memcpy(out[4..36], &node.bytes);
    return out;
}

/// Extract the 20-byte address right-aligned in the first 32-byte return word.
/// Returns null for a short return or the zero address ("no record").
fn addressFromReturn(ret: []const u8) ?Address {
    if (ret.len < 32) return null;
    var addr = Address.zero;
    @memcpy(&addr.bytes, ret[12..32]);
    if (addr.isZero()) return null;
    return addr;
}

/// Forward-verify that `claimed_name`'s coin-type-60 address is `address`, reading
/// at the pinned block `(block_num, block_hash)`. Never throws on a resolution
/// failure — those collapse to `.unverified`.
pub fn verify(
    resolver: *Resolver,
    allocator: std.mem.Allocator,
    registry: Address,
    address: Address,
    claimed_name: []const u8,
    block_num: u64,
    block_hash: Hash,
    now: i64,
) !Verdict {
    // A non-normalized claim is a confusable/spoof and never verifies. Namehash the
    // normalized form so the forward check and any display agree.
    const norm = (try normalizedClaimOwned(allocator, claimed_name)) orelse return .invalid_name;
    defer allocator.free(norm);
    const node = try hash_mod.namehash(allocator, norm);

    // 1. Which resolver does the registry name to for this node?
    const resolver_call = buildNodeCall(sel_resolver, node);
    const r_entry = try resolver.callCached(allocator, registry, "resolver", &resolver_call, block_num, block_hash, now);
    defer r_entry.deinit(allocator);
    if (r_entry.status != .success) return .unverified;
    const resolver_addr = addressFromReturn(r_entry.value orelse return .not_found) orelse return .not_found;

    // 2. What forward address does that resolver report for the node?
    const addr_call = buildNodeCall(sel_addr, node);
    const a_entry = try resolver.callCached(allocator, resolver_addr, "addr:60", &addr_call, block_num, block_hash, now);
    defer a_entry.deinit(allocator);
    if (a_entry.status != .success) return .unverified;
    const forward = addressFromReturn(a_entry.value orelse return .not_found) orelse return .not_found;

    return if (forward.eql(address)) .verified else .mismatch;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hardcoded selectors match their signatures" {
    // Self-check: recompute the 4-byte selectors from their canonical signatures
    // so a wrong constant can never silently ship.
    try testing.expectEqualSlices(u8, &sel_resolver, cache.argHash("resolver(bytes32)").bytes[0..4]);
    try testing.expectEqualSlices(u8, &sel_addr, cache.argHash("addr(bytes32)").bytes[0..4]);
}

test "buildNodeCall lays out selector ++ node" {
    const node = Hash{ .bytes = [_]u8{0xab} ** 32 };
    const call = buildNodeCall(sel_addr, node);
    try testing.expectEqualSlices(u8, &sel_addr, call[0..4]);
    try testing.expectEqualSlices(u8, &node.bytes, call[4..36]);
}

test "addressFromReturn extracts the trailing 20 bytes" {
    // A 32-byte word: 12 leading zero bytes then a 20-byte address.
    var word = [_]u8{0} ** 32;
    const want = [_]u8{0x11} ** 20;
    @memcpy(word[12..32], &want);
    const got = addressFromReturn(&word) orelse return error.ExpectedAddress;
    try testing.expectEqualSlices(u8, &want, &got.bytes);
}

test "addressFromReturn rejects zero and short returns" {
    try testing.expect(addressFromReturn(&([_]u8{0} ** 32)) == null); // zero address
    try testing.expect(addressFromReturn(&([_]u8{0xff} ** 20)) == null); // too short
    try testing.expect(addressFromReturn(&[_]u8{}) == null); // empty
}

test "verify: verified / mismatch / unverified from seeded cache (canned eth_call, no RPC)" {
    const a = testing.allocator;
    const db_mod = @import("../storage/database.zig");
    var db = try db_mod.Database.init(a, ":memory:");
    defer db.deinit();

    const chain_id: u64 = 1;
    const now: i64 = 1000;
    const block_num: u64 = 100;
    const block_hash = try Hash.fromHex("0x" ++ ("11" ** 32));
    const registry = try Address.fromHex("0x00000000000000000000000000000000000000ce");
    const claimant = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const resolver_addr = try Address.fromHex("0x2222222222222222222222222222222222222222");

    // 32-byte ABI return word with `addr` right-aligned in the low 20 bytes.
    const addrReturn = struct {
        fn make(addr: Address) [32]u8 {
            var w = [_]u8{0} ** 32;
            @memcpy(w[12..32], &addr.bytes);
            return w;
        }
    }.make;

    // rpc_client UNDEFINED: every step below is a FRESH cache hit, so the eth_call path is
    // never reached — this both cans the responses and proves verify() reads them from cache.
    var resolver = Resolver{ .rpc_client = undefined, .db = &db, .chain_id = chain_id, .ttl_s = 3600 };

    // Helper: seed registry.resolver(node)=resolver_addr and resolver.addr(node)=forward.
    const seed = struct {
        fn go(dbp: *db_mod.Database, cid: u64, reg: Address, radr: Address, name: []const u8, forward: ?Address, bnum: u64, bhash: Hash, t: i64) !void {
            const node = try hash_mod.namehash(std.testing.allocator, name);
            const rcall = buildNodeCall(sel_resolver, node);
            const rret = addrReturnStatic(radr);
            try cache.put(dbp, .{ .chain_id = cid, .target = reg, .selector_key = "resolver", .arg_hash = cache.argHash(&rcall), .block_dep_num = bnum, .block_dep_hash = bhash }, .success, &rret, .resolved_live, t);
            if (forward) |f| {
                const acall = buildNodeCall(sel_addr, node);
                const aret = addrReturnStatic(f);
                try cache.put(dbp, .{ .chain_id = cid, .target = radr, .selector_key = "addr:60", .arg_hash = cache.argHash(&acall), .block_dep_num = bnum, .block_dep_hash = bhash }, .success, &aret, .resolved_live, t);
            }
        }
        fn addrReturnStatic(addr: Address) [32]u8 {
            var w = [_]u8{0} ** 32;
            @memcpy(w[12..32], &addr.bytes);
            return w;
        }
    }.go;
    _ = addrReturn;

    // VERIFIED — the resolver reports the claiming address.
    try seed(&db, chain_id, registry, resolver_addr, "alice.eth", claimant, block_num, block_hash, now);
    try testing.expectEqual(Verdict.verified, try verify(&resolver, a, registry, claimant, "alice.eth", block_num, block_hash, now));

    // MISMATCH — the resolver reports a DIFFERENT address.
    const other = try Address.fromHex("0x3333333333333333333333333333333333333333");
    try seed(&db, chain_id, registry, resolver_addr, "carol.eth", other, block_num, block_hash, now);
    try testing.expectEqual(Verdict.mismatch, try verify(&resolver, a, registry, claimant, "carol.eth", block_num, block_hash, now));

    // UNVERIFIED — registry.resolver(node) reverted (no resolver on-chain); fail-closed.
    {
        const node = try hash_mod.namehash(a, "bob.eth");
        const rcall = buildNodeCall(sel_resolver, node);
        try cache.put(&db, .{ .chain_id = chain_id, .target = registry, .selector_key = "resolver", .arg_hash = cache.argHash(&rcall), .block_dep_num = block_num, .block_dep_hash = block_hash }, .reverted, null, .resolved_live, now);
        try testing.expectEqual(Verdict.unverified, try verify(&resolver, a, registry, claimant, "bob.eth", block_num, block_hash, now));
    }

    // INVALID_NAME — a non-normalized claim (uppercase) is rejected before any read.
    try testing.expectEqual(Verdict.invalid_name, try verify(&resolver, a, registry, claimant, "Alice.eth", block_num, block_hash, now));

    // NOT_FOUND — registry.resolver(node) succeeds but reports the zero address (no resolver).
    {
        const node = try hash_mod.namehash(a, "dave.eth");
        const rcall = buildNodeCall(sel_resolver, node);
        const zero_word = [_]u8{0} ** 32;
        try cache.put(&db, .{ .chain_id = chain_id, .target = registry, .selector_key = "resolver", .arg_hash = cache.argHash(&rcall), .block_dep_num = block_num, .block_dep_hash = block_hash }, .success, &zero_word, .resolved_live, now);
        try testing.expectEqual(Verdict.not_found, try verify(&resolver, a, registry, claimant, "dave.eth", block_num, block_hash, now));
    }
}

test "normalizedClaimOwned accepts normalized names and rejects non-normalized" {
    const a = testing.allocator;
    const ok = (try normalizedClaimOwned(a, "alice.eth")) orelse return error.ExpectedNormalized;
    defer a.free(ok);
    try testing.expectEqualStrings("alice.eth", ok);
    try testing.expect((try normalizedClaimOwned(a, "Alice.eth")) == null); // uppercase -> not normalized
    try testing.expect((try normalizedClaimOwned(a, "")) == null); // empty -> invalid
}
