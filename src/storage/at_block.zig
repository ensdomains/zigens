//! Single-entity time-travel reconstruction (V2): rebuild one name's state as of a
//! past block by replaying its stored events in memory. This is the query-time
//! counterpart of the indexer's replay layer — same event semantics, but applied to
//! a transient struct instead of the live tables, scoped to one namehash, and free
//! of indexer/config dependencies so the API graph can use it.
//!
//! Honest boundaries (documented in the GraphQL schema):
//! - V2 only. V1 projections are partly pass-derived (rainbow labels, pre-migration
//!   backfills) and have no per-event history for those parts.
//! - Events stored with a NULL/foreign namehash escape the per-name scan (e.g. a
//!   ResolverUpdated recorded under another node but applied by token id at index
//!   time); resolver state can diverge for such names.
//! - Provenance fields (migrated / wrapper carry-over / registry fallback) are
//!   overlaid from the CURRENT row when it is the same registration incarnation
//!   (created_block match); for a since-burned incarnation they degrade to defaults.
//! - `updated_at`/`updated_block` are not reconstructed; callers present the queried
//!   block instead.

const std = @import("std");
const db_mod = @import("database.zig");
const Database = db_mod.Database;
const Query = db_mod.Query;
const models = @import("../types/models.zig");
const hash_mod = @import("../types/hash.zig");
const Hash = hash_mod.Hash;
const Address = @import("../types/address.zig").Address;
const token_id_utils = @import("../types/token_id.zig");

/// Locate the raw value token that follows `"key":` in COMPACT JSON (no spaces, as emitted
/// by the handlers). Requires the key to be preceded by `{` or `,` so a suffix key like
/// `tokenId` never matches inside `oldTokenId`/`newTokenId`. Returns the slice starting at
/// the value (caller interprets string vs number), or null if absent.
pub fn jsonRawValue(data: []const u8, key: []const u8) ?[]const u8 {
    var pat_buf: [64]u8 = undefined;
    if (key.len + 3 > pat_buf.len) return null;
    const pat = std.fmt.bufPrint(&pat_buf, "\"{s}\":", .{key}) catch return null;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, pat)) |pos| {
        if (pos == 0 or data[pos - 1] == '{' or data[pos - 1] == ',') return data[pos + pat.len ..];
        i = pos + 1;
    }
    return null;
}

/// Extract a JSON string value `"key":"<value>"` (value has no escaped quotes in our data).
pub fn jsonString(data: []const u8, key: []const u8) ?[]const u8 {
    const rest = jsonRawValue(data, key) orelse return null;
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

/// Extract a decimal integer value (bare `123` or quoted `"123"`) as u256 — lossless,
/// unlike json_extract. Null if absent/non-numeric.
pub fn jsonU256(data: []const u8, key: []const u8) ?u256 {
    var rest = jsonRawValue(data, key) orelse return null;
    if (rest.len > 0 and rest[0] == '"') rest = rest[1..];
    var n: usize = 0;
    while (n < rest.len and rest[n] >= '0' and rest[n] <= '9') n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u256, rest[0..n], 10) catch null;
}

pub fn jsonU64(data: []const u8, key: []const u8) ?u64 {
    const v = jsonU256(data, key) orelse return null;
    if (v > std.math.maxInt(u64)) return @truncate(v);
    return @intCast(v);
}

const AT_BLOCK_SQL =
    \\SELECT event_type, block_number, tx_hash, log_index, contract_address,
    \\       name, namehash, timestamp, data
    \\FROM events WHERE protocol = 'v2' AND namehash = ?1 AND block_number <= ?2
    \\ORDER BY block_number ASC, log_index ASC
;
const COL_EVENT_TYPE = 0;
const COL_BLOCK_NUMBER = 1;
const COL_CONTRACT = 4;
const COL_NAME = 5;
const COL_TIMESTAMP = 7;
const COL_DATA = 8;

/// One name's reconstructed state as of a block. `name == null` means the name did
/// not exist at that block (never registered, or burned). Resolver records are keyed
/// by the resolver that wrote them — serve the entries matching `name.resolver`.
pub const AtBlockState = struct {
    allocator: std.mem.Allocator,
    name: ?models.Name = null,
    /// "a|<resolver_hex>|<coinType>" / "t|<resolver_hex>|<key>" / "c|<resolver_hex>"
    /// -> owned record value. Last-writer-wins; empty text deletes.
    records: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) AtBlockState {
        return .{ .allocator = allocator, .records = std.StringHashMap([]const u8).init(allocator) };
    }

    pub fn deinit(self: *AtBlockState) void {
        if (self.name) |*n| n.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.records.deinit();
    }

    fn putRecord(self: *AtBlockState, key: []const u8, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);
        const gop = try self.records.getOrPut(key);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = owned_value;
            return;
        }
        // getOrPut stored the caller's (stack) key slice; replace it with an owned
        // dupe or unwind the insertion — a poisoned entry would make deinit free a
        // dangling stack pointer.
        gop.key_ptr.* = self.allocator.dupe(u8, key) catch |err| {
            self.records.removeByPtr(gop.key_ptr);
            return err;
        };
        gop.value_ptr.* = owned_value;
    }

    fn removeRecord(self: *AtBlockState, key: []const u8) void {
        if (self.records.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    pub fn lookupAddr(self: *const AtBlockState, resolver: Address, coin_type: u64) ?[]const u8 {
        var kbuf: [128]u8 = undefined;
        var rbuf: [42]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "a|{s}|{d}", .{ resolver.toHexBuf(&rbuf), coin_type }) catch return null;
        return self.records.get(key);
    }

    pub fn lookupText(self: *const AtBlockState, resolver: Address, text_key: []const u8) ?[]const u8 {
        var kbuf: [512]u8 = undefined;
        var rbuf: [42]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "t|{s}|{s}", .{ resolver.toHexBuf(&rbuf), text_key }) catch return null;
        return self.records.get(key);
    }

    pub fn lookupContenthash(self: *const AtBlockState, resolver: Address) ?[]const u8 {
        var kbuf: [64]u8 = undefined;
        var rbuf: [42]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "c|{s}", .{resolver.toHexBuf(&rbuf)}) catch return null;
        return self.records.get(key);
    }
};

/// Rebuild one V2 name (and its resolver records) as of `block` from the stored event
/// log. Allocations land on `allocator`; the caller owns the returned state.
pub fn reconstructV2AtBlock(database: *Database, allocator: std.mem.Allocator, namehash: Hash, block: u64) !AtBlockState {
    var st = AtBlockState.init(allocator);
    errdefer st.deinit();

    {
        var q = try Query.init(database, AT_BLOCK_SQL);
        defer q.deinit();
        try q.bindHash(namehash);
        try q.bindInt64(@intCast(block));

        while (try q.step()) {
            const et = models.EventType.fromString(q.getTextSlice(COL_EVENT_TYPE) orelse continue) orelse continue;
            const data = q.getTextSlice(COL_DATA) orelse continue;
            applyEvent(&st, &q, et, data, namehash) catch |err| {
                std.log.warn("at-block apply error event={s}: {}", .{ q.getTextSlice(COL_EVENT_TYPE) orelse "?", err });
            };
        }
    }

    try overlayProvenance(&st, database, namehash);
    return st;
}

fn applyEvent(st: *AtBlockState, q: *Query, et: models.EventType, data: []const u8, namehash: Hash) !void {
    const a = st.allocator;
    switch (et) {
        .label_registered, .label_reserved => try applyRegistration(st, q, data, namehash, et == .label_reserved),
        .transfer => {
            const to = Address.fromHex(jsonString(data, "to") orelse return) catch return;
            if (st.name) |*n| n.owner = to;
        },
        .name_renewed => {
            const exp = jsonU64(data, "newExpiry") orelse jsonU64(data, "newExpiration") orelse return;
            if (st.name) |*n| n.expiry = exp;
        },
        .expiry_updated => {
            const exp = jsonU64(data, "newExpiry") orelse return;
            if (st.name) |*n| n.expiry = exp;
        },
        .resolver_updated => {
            // Same key as live: only apply when (tokenId, emitting registry) match the
            // name this event targets — a ResolverUpdated for the same node emitted by
            // a different registry must not touch it.
            const token_id = jsonU256(data, "tokenId") orelse return;
            const contract_addr = Address.fromHex(q.getTextSlice(COL_CONTRACT) orelse return) catch return;
            const r = Address.fromHex(jsonString(data, "resolver") orelse return) catch return;
            if (st.name) |*n| {
                if (n.token_id == token_id and n.registry.eql(contract_addr)) n.resolver = r;
            }
        },
        .token_regenerated => {
            const nt = jsonU256(data, "newTokenId") orelse return;
            if (st.name) |*n| {
                // Match live updateNameTokenIdByNamehash: token_id + token_version
                // change, canonical_id keeps the registration-time value.
                n.token_id = nt;
                n.token_version = token_id_utils.getTokenVersion(nt);
            }
        },
        .name_burned => {
            if (st.name) |*n| n.deinit(a);
            st.name = null;
        },
        .address_changed, .text_changed, .contenthash_changed => try applyRecord(st, et, data),
        else => {},
    }
}

/// Mirror replayV2LabelRegistered/-Reserved minus migration context (overlaid later):
/// the handler froze the fully-qualified name into the event columns, so parent data
/// is re-derived from the name string itself.
fn applyRegistration(st: *AtBlockState, q: *Query, data: []const u8, namehash: Hash, reserved: bool) !void {
    const a = st.allocator;
    const full_name_src = q.getTextSlice(COL_NAME) orelse return;
    const dot = std.mem.indexOfScalar(u8, full_name_src, '.') orelse return;
    const token_id = jsonU256(data, "tokenId") orelse return;
    const owner = if (reserved)
        Address.zero
    else
        Address.fromHex(jsonString(data, "owner") orelse return) catch return;

    // Re-registration replaces the previous incarnation.
    if (st.name) |*prev| prev.deinit(a);
    st.name = null;

    // Name.deinit frees name/label/parent_name independently, so build all three as
    // separate allocations BEFORE assigning st.name — a partial failure must never
    // leave st.name holding slices of a freed buffer.
    const full_name = try a.dupe(u8, full_name_src);
    errdefer a.free(full_name);
    const label = try a.dupe(u8, full_name_src[0..dot]);
    errdefer a.free(label);
    const parent_name = try a.dupe(u8, full_name_src[dot + 1 ..]);
    errdefer a.free(parent_name);

    const registry = if (jsonString(data, "registry")) |r|
        (Address.fromHex(r) catch Address.zero)
    else
        Address.zero; // config fallback unavailable here; overlaid from the current row

    const block_number: u64 = @intCast(q.getInt64(COL_BLOCK_NUMBER));
    const timestamp = q.getInt64(COL_TIMESTAMP);

    st.name = models.Name{
        .name = full_name,
        .label = label,
        .label_hash = try hash_mod.keccak256(a, label),
        .parent_name = parent_name,
        .parent_namehash = try hash_mod.namehash(a, parent_name),
        .protocol = .v2,
        .registry = registry,
        .owner = owner,
        .registrant = owner,
        .resolver = Address.zero,
        .token_id = token_id,
        .canonical_id = token_id_utils.getCanonicalId(token_id),
        .token_version = token_id_utils.getTokenVersion(token_id),
        .namehash = namehash,
        .expiry = jsonU64(data, "expiry") orelse 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = block_number,
        .created_at = timestamp,
        .registered_at = timestamp,
        .updated_block = block_number,
        .updated_at = timestamp,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

fn applyRecord(st: *AtBlockState, et: models.EventType, data: []const u8) !void {
    const a = st.allocator;
    // std.json (not the compact hand-parser): text values are RFC-8259-escaped in
    // event_data and must unescape back to the stored form.
    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const resolver_hex = switch (obj.get("resolver") orelse return) {
        .string => |s| s,
        else => return,
    };
    const resolver = Address.fromHex(resolver_hex) catch return;
    var rbuf: [42]u8 = undefined;
    const rhex = resolver.toHexBuf(&rbuf);

    var kbuf: [512]u8 = undefined;
    switch (et) {
        .address_changed => {
            const coin_type: u64 = switch (obj.get("coinType") orelse return) {
                .integer => |i| @intCast(i),
                else => return,
            };
            const address = switch (obj.get("address") orelse return) {
                .string => |s| s,
                else => return,
            };
            const key = std.fmt.bufPrint(&kbuf, "a|{s}|{d}", .{ rhex, coin_type }) catch return;
            try st.putRecord(key, address);
        },
        .contenthash_changed => {
            const ch = switch (obj.get("contentHash") orelse return) {
                .string => |s| s,
                else => return,
            };
            const key = std.fmt.bufPrint(&kbuf, "c|{s}", .{rhex}) catch return;
            try st.putRecord(key, ch);
        },
        .text_changed => {
            const text_key = switch (obj.get("key") orelse return) {
                .string => |s| s,
                else => return,
            };
            const value: []const u8 = if (obj.get("value")) |v| switch (v) {
                .string => |s| s,
                else => "",
            } else "";
            if (text_key.len > 400) return; // unbatchable key; bufPrint below would fail anyway
            const key = std.fmt.bufPrint(&kbuf, "t|{s}|{s}", .{ rhex, text_key }) catch return;
            if (value.len == 0) {
                st.removeRecord(key);
            } else {
                try st.putRecord(key, value);
            }
        },
        else => {},
    }
}

/// Copy set-once provenance from the CURRENT row when it is the same registration
/// incarnation. These fields come from index-time context (migration controller
/// config, V1 row lookup, registry config fallback) that the event log alone does
/// not carry — and no V2 event ever mutates them, so the copy is exact.
fn overlayProvenance(st: *AtBlockState, database: *Database, namehash: Hash) !void {
    const n = if (st.name) |*n| n else return;
    const cur_row = database.getNameByNamehashAndProtocol(namehash, .v2) catch null orelse return;
    var cur = cur_row;
    defer cur.deinit(database.allocator);
    if (cur.created_block != n.created_block) return; // different incarnation — keep defaults

    n.migrated = cur.migrated;
    n.is_v1_name = cur.is_v1_name;
    n.is_wrapped = cur.is_wrapped;
    n.wrapper_expiry = cur.wrapper_expiry;
    n.registry_locked = cur.registry_locked;
    if (n.registry.isZero()) n.registry = cur.registry;
    if (cur.wrapper_fuses) |f| n.wrapper_fuses = try st.allocator.dupe(u8, f);
    if (cur.v1_label_hash) |v| n.v1_label_hash = try st.allocator.dupe(u8, v);
}
