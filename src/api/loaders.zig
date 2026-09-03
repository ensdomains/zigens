const std = @import("std");
const db = @import("../storage/database.zig");
const models = @import("../types/models.zig");
const names_filter = @import("../storage/names_filter.zig");
const Address = @import("../types/address.zig").Address;
const Hash = @import("../types/hash.zig").Hash;

/// Composite key length: "0x"+40 resolver + "|" + "0x"+64 namehash.
const RECORD_KEY_LEN = 42 + 1 + 66;

/// Longest text key we batch. Real ENS text keys ("url", "com.twitter", …) are
/// short; a longer key just falls through to a per-row point query.
const MAX_TEXT_KEY_LEN = 256;
const TEXT_KEY_LEN = RECORD_KEY_LEN + 1 + MAX_TEXT_KEY_LEN;

/// Write the "<resolver_hex>|<namehash_hex>" batch key into `buf`. Uses the same
/// lowercase 0x-hex encoding the DB stores (bindAddress/bindHash), so a key built
/// from an (Address, Hash) pair matches one built from the DB's returned hex.
fn writeRecordKey(buf: *[RECORD_KEY_LEN]u8, resolver: Address, namehash: Hash) []const u8 {
    var rbuf: [42]u8 = undefined;
    var nbuf: [66]u8 = undefined;
    const rhex = resolver.toHexBuf(&rbuf);
    const nhex = namehash.toHexBuf(&nbuf);
    @memcpy(buf[0..42], rhex);
    buf[42] = '|';
    @memcpy(buf[43..], nhex);
    return buf[0..];
}

/// Write "<resolver_hex>|<namehash_hex>|<text_key>" into `buf`. Returns null when
/// the text key is too long to batch (caller point-queries instead).
fn writeTextKey(buf: *[TEXT_KEY_LEN]u8, resolver: Address, namehash: Hash, key: []const u8) ?[]const u8 {
    if (key.len > MAX_TEXT_KEY_LEN) return null;
    var rbuf: [42]u8 = undefined;
    var nbuf: [66]u8 = undefined;
    @memcpy(buf[0..42], resolver.toHexBuf(&rbuf));
    buf[42] = '|';
    @memcpy(buf[43..109], namehash.toHexBuf(&nbuf));
    buf[109] = '|';
    @memcpy(buf[110 .. 110 + key.len], key);
    return buf[0 .. 110 + key.len];
}

// ============================================================================
// Per-request loader context
// ============================================================================
//
// All previous ENS-specific loaders (resolver_address, content_hash, text_records)
// were removed because they had a namehash-only batching key that leaked
// legacy-resolver records for migrated names. See:
//   - src/api/builders/impl.zig — handlers bypass the loader layer and query
//     with (resolver, namehash) for correctness.
//   - schema/022_resolver_composite_unique.sql — enforces the invariant at the DB.
//
// The struct is kept as a zero-field stub so existing plumbing in handler.zig and
// the executor's `loaders: ?*anyopaque` field remains valid. Future batching would
// add fields here, keyed appropriately to avoid the legacy bug.
pub const LoaderContext = struct {
    allocator: std.mem.Allocator,
    /// Per-request memoization for Account rows. The four `seenV1` / `seenV2` /
    /// `firstSeenBlock` / `firstSeenTimestamp` field handlers each fetch the
    /// same row; in list queries that pull all four, the per-row count drops
    /// from 4 → 1 with this cache. Keyed by 0x-prefixed lowercase address;
    /// the entry value is the loaded row (or null sentinel for "looked up,
    /// no such account"). Cache keys live on `allocator` (the request arena);
    /// the row values' inner slices are owned by `db_allocator` — db.getAccount
    /// dupes `.address` on the persistent db allocator, not the arena — so
    /// deinit must free both explicitly.
    account_cache: std.StringHashMap(?db.Account),
    db_allocator: std.mem.Allocator,

    /// Per-page batch prefetch of the two single-value resolver record reads,
    /// keyed by the composite "<resolver_hex>|<namehash_hex>" (see writeRecordKey)
    /// — the (resolver, namehash) pair the handlers query with. Populated once per
    /// list page in resolveDomains, so a page selecting `resolver{ addr }` /
    /// `resolvedAddress` / `resolver{ contentHash }` does ONE query per record type
    /// instead of one per row. Key present + null = "batched, no record"; key
    /// absent = not batched (handler falls back to the point query). Map values are
    /// db-allocator-owned; keys are arena-owned.
    addr60: std.StringHashMap(?[]const u8),
    contenthash: std.StringHashMap(?[]const u8),
    /// text(key:) records, keyed by "<resolver_hex>|<namehash_hex>|<text_key>".
    texts: std.StringHashMap(?[]const u8),
    /// `texts` key-LIST field, keyed by "<resolver_hex>|<namehash_hex>". Value
    /// = the pair's complete DISTINCT-key list in the point query's ORDER BY
    /// key order (possibly empty). Key present = batched; absent = fall back.
    /// Committed ATOMICALLY per pair (built fully first), so partial failure
    /// can only mean absent-→-fallback, never a wrong empty list. Keys and
    /// values are arena-owned.
    text_key_lists: std.StringHashMap([]const []const u8),
    /// `coinTypes` scalar-LIST field, keyed by "<resolver_hex>|<namehash_hex>".
    /// Same contract and per-pair atomic commit discipline as text_key_lists:
    /// key present = the pair's complete ascending coin-type list (possibly
    /// empty); absent = fall back. Keys and list slices are arena-owned.
    coin_type_lists: std.StringHashMap([]const u64),
    /// Per-page batch prefetch of each account's nested `domains` page
    /// (accounts lists resolve it per row otherwise — the N+1 behind the 36s
    /// Grafana max). Keyed by 0x-lowercase owner hex; value = EXACTLY the
    /// page getAllNames(owner, skip, first) returns (possibly empty). Valid
    /// only for the (skip, first) recorded at populate time — lookups with
    /// different args fall back. Rows are db-allocator-owned.
    account_domains: std.StringHashMap([]models.Name),
    account_domains_skip: u32 = 0,
    account_domains_first: u32 = 0,

    /// Per-page batch prefetch of Domain rows for event-shaped parents
    /// (registrations/events lists resolving `domain { … }` per row). Key
    /// present + null = "batched, no row"; key present + row = the namehash's
    /// SINGLE row; key ABSENT = not batched OR the namehash has multiple rows
    /// (v1/v2 same-namehash) — the handler falls back to the point query,
    /// whose unordered first-row pick only SQL can reproduce. Rows are
    /// db-allocator-owned.
    domains: std.AutoHashMap(Hash, ?models.Name),

    pub fn init(allocator: std.mem.Allocator, database: *db.Database) !*LoaderContext {
        const ctx = try allocator.create(LoaderContext);
        ctx.* = .{
            .allocator = allocator,
            .account_cache = std.StringHashMap(?db.Account).init(allocator),
            .db_allocator = database.allocator,
            .addr60 = std.StringHashMap(?[]const u8).init(allocator),
            .contenthash = std.StringHashMap(?[]const u8).init(allocator),
            .texts = std.StringHashMap(?[]const u8).init(allocator),
            .text_key_lists = std.StringHashMap([]const []const u8).init(allocator),
            .coin_type_lists = std.StringHashMap([]const u64).init(allocator),
            .domains = std.AutoHashMap(Hash, ?models.Name).init(allocator),
            .account_domains = std.StringHashMap([]models.Name).init(allocator),
        };
        return ctx;
    }

    /// Batch-prefetch each owner's nested domains page: one windowed IN query
    /// for the whole accounts page. Groups rows per owner and records the
    /// page args; owners with no rows get an explicit empty entry so the
    /// handler's absent-vs-empty distinction stays exact. Best-effort.
    pub fn populateAccountDomains(self: *LoaderContext, database: *db.Database, owners: []const Address, skip: u32, first: u32) void {
        if (owners.len == 0) return;
        const rows = names_filter.getNamesByOwnersPage(database, owners, skip, first, self.db_allocator) catch return;
        defer self.db_allocator.free(rows);
        var consumed: usize = 0;
        self.populateAccountDomainsInner(owners, rows, skip, first, &consumed) catch {};
        for (rows[consumed..]) |row| {
            var mut = row;
            mut.deinit(self.db_allocator);
        }
    }

    fn populateAccountDomainsInner(self: *LoaderContext, owners: []const Address, rows: []models.Name, skip: u32, first: u32, consumed: *usize) !void {
        self.account_domains_skip = skip;
        self.account_domains_first = first;

        // Rows arrive grouped per owner (window partition order); slice them
        // into per-owner sublists without copying the row structs twice.
        var groups = std.StringHashMap(std.ArrayList(models.Name)).init(self.allocator);
        defer {
            var git = groups.iterator();
            while (git.next()) |entry| {
                for (entry.value_ptr.items) |*n| n.deinit(self.db_allocator);
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            groups.deinit();
        }
        for (rows) |row| {
            var owner_buf: [42]u8 = undefined;
            const owner_hex = row.owner.toHexBuf(&owner_buf);
            const gop = try groups.getOrPut(owner_hex);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                // Key-dupe failure must remove the entry while the key still
                // aliases the live stack buffer; the row stays unconsumed so
                // the caller's tail sweep frees it.
                gop.key_ptr.* = self.allocator.dupe(u8, owner_hex) catch |err| {
                    _ = groups.remove(owner_hex);
                    return err;
                };
            }
            try gop.value_ptr.append(self.allocator, row);
            // Only now does `groups` own the row — a failure above leaves it
            // in the unconsumed tail.
            consumed.* += 1;
        }

        // Atomic per-owner commit; every requested owner gets a complete page
        // (possibly empty). Failure mid-commit leaves later owners absent —
        // the handler falls back to the point query, which is always correct.
        for (owners) |owner| {
            var owner_buf: [42]u8 = undefined;
            const owner_hex = owner.toHexBuf(&owner_buf);
            if (self.account_domains.contains(owner_hex)) continue;
            const list: []models.Name = blk: {
                if (groups.getPtr(owner_hex)) |gl| break :blk try gl.toOwnedSlice(self.allocator);
                break :blk try self.allocator.alloc(models.Name, 0);
            };
            errdefer {
                for (list) |row| {
                    var mut = row;
                    mut.deinit(self.db_allocator);
                }
                self.allocator.free(list);
            }
            const key_owned = try self.allocator.dupe(u8, owner_hex);
            errdefer self.allocator.free(key_owned);
            try self.account_domains.put(key_owned, list);
        }
    }

    /// Null = not batched for these args (caller point-queries); otherwise the
    /// owner's complete page. Loader-owned; don't free or mutate.
    pub fn lookupAccountDomains(self: *LoaderContext, owner_hex: []const u8, skip: u32, first: u32) ?[]const models.Name {
        if (skip != self.account_domains_skip or first != self.account_domains_first) return null;
        return self.account_domains.get(owner_hex);
    }

    /// Batch-prefetch Domain rows for a page of namehashes: one IN-list query
    /// instead of one getNameByNamehash per row. Namehashes with a single row
    /// cache that row; zero rows cache an explicit "no row"; MULTIPLE rows
    /// (v1/v2 same-namehash) are left absent so the handler's point query
    /// keeps its exact (backend-row-order) semantics. Best-effort: failure
    /// leaves the map un(der)populated and handlers fall back.
    pub fn populateDomains(self: *LoaderContext, database: *db.Database, namehashes: []const Hash) void {
        if (namehashes.len == 0) return;
        const rows = database.getNamesByNamehashes(namehashes, self.db_allocator) catch return;
        defer self.db_allocator.free(rows);
        var consumed: usize = 0;
        self.populateDomainsInner(namehashes, rows, &consumed) catch {
            // Failure can strand "no row" sentinels for namehashes whose rows
            // were never processed — a stale sentinel would serve domain:null
            // for a row that exists. Downgrade every still-null sentinel to
            // absent: handlers fall back to the point query, which is always
            // correct (a legitimately-empty namehash just pays one query).
            for (namehashes) |nh| {
                if (self.domains.getPtr(nh)) |slot| {
                    if (slot.* == null) _ = self.domains.remove(nh);
                }
            }
        };
        for (rows[consumed..]) |row| {
            var mut = row;
            mut.deinit(self.db_allocator);
        }
    }

    fn populateDomainsInner(self: *LoaderContext, namehashes: []const Hash, rows: []models.Name, consumed: *usize) !void {
        for (namehashes) |nh| {
            _ = try self.domains.getOrPutValue(nh, null);
        }
        var kept = std.AutoHashMap(Hash, void).init(self.allocator);
        defer kept.deinit();
        for (rows) |row| {
            const gop = try kept.getOrPut(row.namehash);
            consumed.* += 1;
            if (gop.found_existing) {
                // Second row for this namehash: evict the cached one and leave
                // the key absent — only the point query may decide row order.
                if (self.domains.fetchRemove(row.namehash)) |old| {
                    if (old.value) |cached| {
                        var mut = cached;
                        mut.deinit(self.db_allocator);
                    }
                }
                var mut = row;
                mut.deinit(self.db_allocator);
                continue;
            }
            if (self.domains.getPtr(row.namehash)) |slot| {
                // A prior populateDomains call may have cached this namehash
                // already — replace, don't leak.
                if (slot.*) |prior| {
                    var mut = prior;
                    mut.deinit(self.db_allocator);
                }
                slot.* = row;
            } else {
                var mut = row;
                mut.deinit(self.db_allocator);
            }
        }
    }

    /// Outer null = not batched (caller point-queries); inner null = batched,
    /// no row. The returned row is loader-owned — callers must NOT deinit it.
    pub fn lookupDomain(self: *LoaderContext, namehash: Hash) ?(?*const models.Name) {
        const slot = self.domains.getPtr(namehash) orelse return null;
        if (slot.*) |*row| return @as(?*const models.Name, row);
        return @as(?*const models.Name, null);
    }

    /// Prefetch the addr(coinType=60) and/or contenthash records for a page of
    /// (resolver, namehash) pairs into the maps, so the per-row resolver handlers
    /// read them from memory. Idempotent-safe to skip when the selection doesn't
    /// touch those fields (pass want_* = false). resolvers[i] pairs with
    /// namehashes[i]. Any failure is swallowed and leaves the maps un(der)populated
    /// — handlers then fall back to point queries, so correctness never depends on
    /// this having run.
    pub fn populateResolverRecords(
        self: *LoaderContext,
        database: *db.Database,
        resolvers: []const Address,
        namehashes: []const Hash,
        want_addr: bool,
        want_contenthash: bool,
    ) void {
        if (want_addr) self.populateInto(&self.addr60, database, resolvers, namehashes, .addr) catch {};
        if (want_contenthash) self.populateInto(&self.contenthash, database, resolvers, namehashes, .contenthash) catch {};
    }

    const RecordKind = enum { addr, contenthash };

    fn populateInto(
        self: *LoaderContext,
        map: *std.StringHashMap(?[]const u8),
        database: *db.Database,
        resolvers: []const Address,
        namehashes: []const Hash,
        kind: RecordKind,
    ) !void {
        // Default every pair to "batched, no record"; overwritten below for pairs
        // that have one. Keys are arena-owned.
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        for (resolvers, namehashes) |r, nh| {
            const key = writeRecordKey(&kbuf, r, nh);
            if (map.contains(key)) continue; // a duplicate (resolver,namehash) on the page
            const owned_key = try self.allocator.dupe(u8, key);
            try map.put(owned_key, null);
        }

        const rows = switch (kind) {
            .addr => try database.getAddressRecordsBatch(resolvers, namehashes, 60),
            .contenthash => try database.getContentHashesBatch(resolvers, namehashes),
        };
        defer self.db_allocator.free(rows);
        for (rows) |*row| {
            // Update the pre-inserted entry's value IN PLACE (no new key), keeping
            // the arena key and taking ownership of the db-owned value.
            const composite_len = row.resolver.len + 1 + row.namehash.len;
            if (composite_len == RECORD_KEY_LEN) {
                var rk: [RECORD_KEY_LEN]u8 = undefined;
                @memcpy(rk[0..row.resolver.len], row.resolver);
                rk[row.resolver.len] = '|';
                @memcpy(rk[row.resolver.len + 1 ..], row.namehash);
                if (map.getEntry(rk[0..])) |e| {
                    // A repeat populate (aliased lists) already owns a value here.
                    if (e.value_ptr.*) |old| self.db_allocator.free(old);
                    e.value_ptr.* = row.value;
                } else {
                    self.db_allocator.free(row.value);
                }
            } else {
                self.db_allocator.free(row.value);
            }
            self.db_allocator.free(row.resolver);
            self.db_allocator.free(row.namehash);
        }
    }

    /// Look up a batched addr(60) record. Outer null = pair was not batched (caller
    /// point-queries); inner value = batched result (may itself be null = no record).
    /// The returned slice is owned by the LoaderContext — do NOT free it.
    pub fn lookupAddr60(self: *LoaderContext, resolver: Address, namehash: Hash) ?(?[]const u8) {
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        return self.addr60.get(writeRecordKey(&kbuf, resolver, namehash));
    }

    pub fn lookupContentHash(self: *LoaderContext, resolver: Address, namehash: Hash) ?(?[]const u8) {
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        return self.contenthash.get(writeRecordKey(&kbuf, resolver, namehash));
    }

    /// Prefetch the given text `keys` for a page of (resolver, namehash) pairs.
    /// One batch query per key (each latest-per-pair), so a page selecting
    /// `resolver{ text(key:"url") }` does one query for "url" across all rows
    /// instead of one per row. Best-effort; misses fall back to point queries.
    pub fn populateTextRecords(
        self: *LoaderContext,
        database: *db.Database,
        resolvers: []const Address,
        namehashes: []const Hash,
        keys: []const []const u8,
    ) void {
        for (keys) |key| self.populateTextKey(database, resolvers, namehashes, key) catch {};
    }

    fn populateTextKey(
        self: *LoaderContext,
        database: *db.Database,
        resolvers: []const Address,
        namehashes: []const Hash,
        key: []const u8,
    ) !void {
        if (key.len > MAX_TEXT_KEY_LEN) return; // unbatchable; handler point-queries
        var kbuf: [TEXT_KEY_LEN]u8 = undefined;
        for (resolvers, namehashes) |r, nh| {
            const ck = writeTextKey(&kbuf, r, nh, key) orelse continue;
            if (self.texts.contains(ck)) continue;
            const owned_key = try self.allocator.dupe(u8, ck);
            try self.texts.put(owned_key, null);
        }

        const rows = try database.getTextRecordsBatch(resolvers, namehashes, key);
        defer self.db_allocator.free(rows);
        for (rows) |*row| {
            // Rebuild the composite key from the row hex + this batch's key, then
            // update the pre-inserted entry in place (keep arena key, take value).
            if (row.resolver.len == 42 and row.namehash.len == 66 and key.len <= MAX_TEXT_KEY_LEN) {
                var rk: [TEXT_KEY_LEN]u8 = undefined;
                @memcpy(rk[0..42], row.resolver);
                rk[42] = '|';
                @memcpy(rk[43..109], row.namehash);
                rk[109] = '|';
                @memcpy(rk[110 .. 110 + key.len], key);
                if (self.texts.getEntry(rk[0 .. 110 + key.len])) |e| {
                    // A repeat populate (aliased lists) already owns a value here.
                    if (e.value_ptr.*) |old| self.db_allocator.free(old);
                    e.value_ptr.* = row.value;
                } else {
                    self.db_allocator.free(row.value);
                }
            } else {
                self.db_allocator.free(row.value);
            }
            self.db_allocator.free(row.resolver);
            self.db_allocator.free(row.namehash);
        }
    }

    /// Look up a batched text(key:) record. Outer null = not batched (point-query);
    /// inner value = batched result (may be null = no record). Loader-owned; don't free.
    pub fn lookupText(self: *LoaderContext, resolver: Address, namehash: Hash, key: []const u8) ?(?[]const u8) {
        var kbuf: [TEXT_KEY_LEN]u8 = undefined;
        const ck = writeTextKey(&kbuf, resolver, namehash, key) orelse return null;
        return self.texts.get(ck);
    }

    /// Batch-prefetch the `texts` key-LIST field for a page of (resolver,
    /// namehash) pairs: one IN-list DISTINCT sweep instead of one point query
    /// per row. Lists are built completely BEFORE any pair is committed to the
    /// map, so a failure can only leave pairs absent (handler falls back) —
    /// never a wrong empty list. Best-effort.
    pub fn populateTextKeyLists(self: *LoaderContext, database: *db.Database, resolvers: []const Address, namehashes: []const Hash) void {
        if (resolvers.len == 0) return;
        const rows = database.getTextRecordKeysForPairs(resolvers, namehashes) catch return;
        defer {
            for (rows) |row| {
                self.db_allocator.free(row.resolver);
                self.db_allocator.free(row.namehash);
                self.db_allocator.free(row.key);
            }
            self.db_allocator.free(rows);
        }
        self.populateTextKeyListsInner(resolvers, namehashes, rows) catch {};
    }

    fn populateTextKeyListsInner(self: *LoaderContext, resolvers: []const Address, namehashes: []const Hash, rows: []const db.PairTextKeyRow) !void {
        // Group per pair in scan order: the batch query's global ORDER BY key
        // makes each pair's sublist arrive in the point query's exact order.
        var grouped = std.StringHashMap(std.ArrayList([]const u8)).init(self.allocator);
        defer {
            var git = grouped.iterator();
            while (git.next()) |entry| {
                for (entry.value_ptr.items) |k| self.allocator.free(k);
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            grouped.deinit();
        }
        for (rows) |row| {
            if (row.resolver.len + 1 + row.namehash.len != RECORD_KEY_LEN) continue;
            var rk: [RECORD_KEY_LEN]u8 = undefined;
            @memcpy(rk[0..row.resolver.len], row.resolver);
            rk[row.resolver.len] = '|';
            @memcpy(rk[row.resolver.len + 1 ..], row.namehash);
            const gop = try grouped.getOrPut(rk[0..]);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                // Key-dupe failure must remove the entry NOW, while its key
                // still aliases the live stack buffer — leaving it would hand
                // the deinit sweep a dangling key.
                gop.key_ptr.* = self.allocator.dupe(u8, rk[0..]) catch |err| {
                    _ = grouped.remove(rk[0..]);
                    return err;
                };
            }
            const key_copy = try self.allocator.dupe(u8, row.key);
            errdefer self.allocator.free(key_copy);
            try gop.value_ptr.append(self.allocator, key_copy);
        }

        // Atomic per-pair commit: every requested pair gets its COMPLETE list.
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        for (resolvers, namehashes) |r, nh| {
            const ck = writeRecordKey(&kbuf, r, nh);
            if (self.text_key_lists.contains(ck)) continue; // page duplicate or repeat priming — first list is already exact
            const list: []const []const u8 = blk: {
                if (grouped.getPtr(ck)) |gl| break :blk try gl.toOwnedSlice(self.allocator);
                break :blk try self.allocator.alloc([]const u8, 0);
            };
            errdefer {
                for (list) |k| self.allocator.free(k);
                self.allocator.free(list);
            }
            const ck_owned = try self.allocator.dupe(u8, ck);
            errdefer self.allocator.free(ck_owned);
            try self.text_key_lists.put(ck_owned, list);
        }
    }

    /// Null = pair was not batched (caller point-queries); otherwise the
    /// pair's complete key list (may be empty). Loader-owned; don't free.
    pub fn lookupTextKeys(self: *LoaderContext, resolver: Address, namehash: Hash) ?[]const []const u8 {
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        const ck = writeRecordKey(&kbuf, resolver, namehash);
        return self.text_key_lists.get(ck);
    }

    /// Batch-prefetch the `coinTypes` scalar-LIST field for a page of
    /// (resolver, namehash) pairs: one IN-list DISTINCT sweep instead of one
    /// point query per row. Same atomic per-pair commit as
    /// populateTextKeyLists — a failure can only leave pairs absent (handler
    /// falls back), never a wrong empty list. Best-effort.
    pub fn populateCoinTypeLists(self: *LoaderContext, database: *db.Database, resolvers: []const Address, namehashes: []const Hash) void {
        if (resolvers.len == 0) return;
        const rows = database.getCoinTypesForPairs(resolvers, namehashes) catch return;
        defer {
            for (rows) |row| {
                self.db_allocator.free(row.resolver);
                self.db_allocator.free(row.namehash);
            }
            self.db_allocator.free(rows);
        }
        self.populateCoinTypeListsInner(resolvers, namehashes, rows) catch {};
    }

    fn populateCoinTypeListsInner(self: *LoaderContext, resolvers: []const Address, namehashes: []const Hash, rows: []const db.PairCoinTypeRow) !void {
        // Group per pair in scan order: the batch query's global ORDER BY
        // coin_type makes each pair's sublist arrive in the point query's
        // exact ascending order.
        var grouped = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);
        defer {
            var git = grouped.iterator();
            while (git.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            grouped.deinit();
        }
        for (rows) |row| {
            if (row.resolver.len + 1 + row.namehash.len != RECORD_KEY_LEN) continue;
            var rk: [RECORD_KEY_LEN]u8 = undefined;
            @memcpy(rk[0..row.resolver.len], row.resolver);
            rk[row.resolver.len] = '|';
            @memcpy(rk[row.resolver.len + 1 ..], row.namehash);
            const gop = try grouped.getOrPut(rk[0..]);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                // Key-dupe failure must remove the entry NOW, while its key
                // still aliases the live stack buffer — leaving it would hand
                // the deinit sweep a dangling key.
                gop.key_ptr.* = self.allocator.dupe(u8, rk[0..]) catch |err| {
                    _ = grouped.remove(rk[0..]);
                    return err;
                };
            }
            try gop.value_ptr.append(self.allocator, row.coin_type);
        }

        // Atomic per-pair commit: every requested pair gets its COMPLETE list.
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        for (resolvers, namehashes) |r, nh| {
            const ck = writeRecordKey(&kbuf, r, nh);
            if (self.coin_type_lists.contains(ck)) continue; // page duplicate or repeat priming — first list is already exact
            const list: []const u64 = blk: {
                if (grouped.getPtr(ck)) |gl| break :blk try gl.toOwnedSlice(self.allocator);
                break :blk try self.allocator.alloc(u64, 0);
            };
            errdefer self.allocator.free(list);
            const ck_owned = try self.allocator.dupe(u8, ck);
            errdefer self.allocator.free(ck_owned);
            try self.coin_type_lists.put(ck_owned, list);
        }
    }

    /// Null = pair was not batched (caller point-queries); otherwise the
    /// pair's complete ascending coin-type list (may be empty). Loader-owned.
    pub fn lookupCoinTypes(self: *LoaderContext, resolver: Address, namehash: Hash) ?[]const u64 {
        var kbuf: [RECORD_KEY_LEN]u8 = undefined;
        const ck = writeRecordKey(&kbuf, resolver, namehash);
        return self.coin_type_lists.get(ck);
    }

    /// Returns the cached row for `address`, fetching from the DB on first miss.
    /// The returned pointer is owned by the LoaderContext (arena-scoped); callers
    /// must not free it.
    pub fn getAccountCached(self: *LoaderContext, database: *db.Database, address: []const u8) !?*const db.Account {
        if (self.account_cache.getPtr(address)) |existing| {
            if (existing.*) |*row| return row;
            return null;
        }
        const fetched = try database.getAccount(address);
        errdefer if (fetched) |acct| {
            var row = acct;
            row.deinit(self.db_allocator);
        };
        // Dupe the key onto the arena so the cache key outlives the caller's `address`.
        const key_owned = try self.allocator.dupe(u8, address);
        try self.account_cache.put(key_owned, fetched);
        if (self.account_cache.getPtr(key_owned)) |slot| {
            if (slot.*) |*row| return row;
        }
        return null;
    }

    pub fn deinit(self: *LoaderContext) void {
        var it = self.account_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*) |acct| {
                var row = acct;
                row.deinit(self.db_allocator); // frees .address (db-allocator-owned)
            }
            self.allocator.free(entry.key_ptr.*); // arena key (no-op on arena; correct on GPA)
        }
        self.account_cache.deinit();

        // Record maps: values are db-allocator-owned, keys are arena-owned.
        inline for (.{ &self.addr60, &self.contenthash, &self.texts }) |map| {
            var mit = map.iterator();
            while (mit.next()) |entry| {
                if (entry.value_ptr.*) |v| self.db_allocator.free(v);
                self.allocator.free(entry.key_ptr.*);
            }
            map.deinit();
        }

        // texts key-lists: keys, list slices, and list items all arena-owned.
        var tkit = self.text_key_lists.iterator();
        while (tkit.next()) |entry| {
            for (entry.value_ptr.*) |k| self.allocator.free(k);
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.text_key_lists.deinit();

        // coinTypes lists: keys and list slices arena-owned (u64 items inline).
        var ctit = self.coin_type_lists.iterator();
        while (ctit.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.coin_type_lists.deinit();

        // Account-domains pages: rows db-allocator-owned, keys+slices arena-owned.
        var adit = self.account_domains.iterator();
        while (adit.next()) |entry| {
            for (entry.value_ptr.*) |row| {
                var mut = row;
                mut.deinit(self.db_allocator);
            }
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.account_domains.deinit();

        // Domain rows are db-allocator-owned; keys are plain Hash values.
        var dit = self.domains.iterator();
        while (dit.next()) |entry| {
            if (entry.value_ptr.*) |row| {
                var mut = row;
                mut.deinit(self.db_allocator);
            }
        }
        self.domains.deinit();

        self.allocator.destroy(self);
    }
};

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Tests for Content Hash and Text Records Loaders
// ============================================================================

test "LoaderContext: init and deinit" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();
}

fn testDomainRow(n: u8, protocol: models.Protocol, name_str: []const u8) models.Name {
    var h = Hash{ .bytes = [_]u8{0} ** 32 };
    h.bytes[31] = n;
    h.bytes[0] = 0x0D;
    return models.Name{
        .protocol = protocol,
        .name = name_str,
        .namehash = h,
        .label = name_str,
        .label_hash = h,
        .parent_name = "",
        .parent_namehash = Hash.zero,
        .registry = Address{ .bytes = [_]u8{0xC1} ** 20 },
        .owner = Address{ .bytes = [_]u8{0xA1} ** 20 },
        .registrant = Address{ .bytes = [_]u8{0xA1} ** 20 },
        .resolver = Address.zero,
        .token_id = n,
        .canonical_id = n,
        .token_version = 1,
        .expiry = 0,
        .registry_locked = false,
        .migrated = false,
        .created_block = 100,
        .created_at = 1700000000,
        .registered_at = 1700000000,
        .updated_block = 100,
        .updated_at = 1700000000,
        .is_wrapped = false,
        .wrapper_fuses = null,
        .wrapper_expiry = null,
        .is_v1_name = false,
        .v1_label_hash = null,
    };
}

test "populateTextKeyLists: ordered lists, empty batched, unbatched null, repeat-safe" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const res_a = Address{ .bytes = [_]u8{0xE1} ** 20 };
    const res_b = Address{ .bytes = [_]u8{0xE2} ** 20 };
    var nh_a = Hash{ .bytes = [_]u8{0} ** 32 };
    nh_a.bytes[31] = 1;
    var nh_b = Hash{ .bytes = [_]u8{0} ** 32 };
    nh_b.bytes[31] = 2;
    const tx = Hash{ .bytes = [_]u8{0xAB} ** 32 };

    // Pair A: two keys (inserted out of key order — the batch must serve them
    // ORDER BY key, matching the point query). Same key twice = one DISTINCT.
    try test_db.storeResolverText(nh_a, res_a, "url", "https://x", .v2, 100, tx, 1700000000);
    try test_db.storeResolverText(nh_a, res_a, "avatar", "https://a", .v2, 101, tx, 1700000001);
    try test_db.storeResolverText(nh_a, res_a, "avatar", "https://a2", .v2, 102, tx, 1700000002);
    // Same namehash under a DIFFERENT resolver: must not leak into pair A
    // (the exact bug that killed the old namehash-only DataLoader).
    try test_db.storeResolverText(nh_a, res_b, "legacy-key", "v", .v2, 103, tx, 1700000003);

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    const pair_resolvers = [_]Address{ res_a, res_a };
    const pair_namehashes = [_]Hash{ nh_a, nh_b };
    ctx.populateTextKeyLists(&test_db, &pair_resolvers, &pair_namehashes);

    const keys_a = ctx.lookupTextKeys(res_a, nh_a) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 2), keys_a.len);
    try std.testing.expectEqualStrings("avatar", keys_a[0]);
    try std.testing.expectEqualStrings("url", keys_a[1]);

    // Batched pair with zero records: complete empty list, not a fallback.
    const keys_b = ctx.lookupTextKeys(res_a, nh_b) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 0), keys_b.len);

    // Unbatched pair: null → handler point-queries (res_b was never primed).
    try std.testing.expectEqual(@as(?[]const []const u8, null), ctx.lookupTextKeys(res_b, nh_a));

    // Batched answers must equal the point query.
    const point = try test_db.getTextRecordKeys(res_a, nh_a);
    defer {
        for (point) |k| test_db.allocator.free(k);
        test_db.allocator.free(point);
    }
    try std.testing.expectEqual(point.len, keys_a.len);
    for (point, keys_a) |p, b| try std.testing.expectEqualStrings(p, b);

    // Repeat priming keeps the first (equal) list and must not leak.
    ctx.populateTextKeyLists(&test_db, &pair_resolvers, &pair_namehashes);
    const again = ctx.lookupTextKeys(res_a, nh_a) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 2), again.len);
}

test "populateCoinTypeLists: ordered lists, empty batched, unbatched null, repeat-safe" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    const res_a = Address{ .bytes = [_]u8{0xE1} ** 20 };
    const res_b = Address{ .bytes = [_]u8{0xE2} ** 20 };
    var nh_a = Hash{ .bytes = [_]u8{0} ** 32 };
    nh_a.bytes[31] = 1;
    var nh_b = Hash{ .bytes = [_]u8{0} ** 32 };
    nh_b.bytes[31] = 2;
    const tx = Hash{ .bytes = [_]u8{0xAB} ** 32 };

    // Pair A: inserted out of ascending order (the batch must serve them
    // ORDER BY coin_type, matching the point query), including an ENSIP-11
    // L2 coin type past Int32. Same coin type under BOTH protocols = one
    // DISTINCT entry, exactly like the point query.
    try test_db.storeResolverAddress(nh_a, res_a, 2147483658, "0xaa", .v2, 100, tx, 1700000000);
    try test_db.storeResolverAddress(nh_a, res_a, 60, "0xbb", .v2, 101, tx, 1700000001);
    try test_db.storeResolverAddress(nh_a, res_a, 60, "0xcc", .v1, 102, tx, 1700000002);
    // Same namehash under a DIFFERENT resolver: must not leak into pair A.
    try test_db.storeResolverAddress(nh_a, res_b, 0, "0xdd", .v2, 103, tx, 1700000003);

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    const pair_resolvers = [_]Address{ res_a, res_a };
    const pair_namehashes = [_]Hash{ nh_a, nh_b };
    ctx.populateCoinTypeLists(&test_db, &pair_resolvers, &pair_namehashes);

    const cts_a = ctx.lookupCoinTypes(res_a, nh_a) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 2), cts_a.len);
    try std.testing.expectEqual(@as(u64, 60), cts_a[0]);
    try std.testing.expectEqual(@as(u64, 2147483658), cts_a[1]);

    // Batched pair with zero records: complete empty list, not a fallback.
    const cts_b = ctx.lookupCoinTypes(res_a, nh_b) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 0), cts_b.len);

    // Unbatched pair: null → handler point-queries (res_b was never primed).
    try std.testing.expectEqual(@as(?[]const u64, null), ctx.lookupCoinTypes(res_b, nh_a));

    // Batched answers must equal the point query.
    const point = try test_db.getCoinTypes(res_a, nh_a);
    defer test_db.allocator.free(point);
    try std.testing.expectEqual(point.len, cts_a.len);
    for (point, cts_a) |p, b| try std.testing.expectEqual(p, b);

    // Repeat priming keeps the first (equal) list and must not leak.
    ctx.populateCoinTypeLists(&test_db, &pair_resolvers, &pair_namehashes);
    const again = ctx.lookupCoinTypes(res_a, nh_a) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(usize, 2), again.len);
}

test "populateDomains: single-row cached, multi-row absent, zero-row sentinel, repeat-safe" {
    const allocator = std.testing.allocator;

    var test_db = try db.Database.init(allocator, ":memory:");
    defer test_db.deinit();

    try test_db.insertName(testDomainRow(1, .v2, "solo.eth"));
    // Same namehash under BOTH protocols: the point query's row pick is
    // backend-order-dependent, so the batch must refuse to cache it.
    try test_db.insertName(testDomainRow(2, .v1, "dual.eth"));
    try test_db.insertName(testDomainRow(2, .v2, "dual-v2.eth"));

    const ctx = try LoaderContext.init(allocator, &test_db);
    defer ctx.deinit();

    const nh = struct {
        fn of(n: u8) Hash {
            var h = Hash{ .bytes = [_]u8{0} ** 32 };
            h.bytes[31] = n;
            h.bytes[0] = 0x0D;
            return h;
        }
    }.of;

    const page = [_]Hash{ nh(1), nh(2), nh(3) };
    ctx.populateDomains(&test_db, &page);

    const solo = ctx.lookupDomain(nh(1)) orelse return error.ExpectedBatched;
    try std.testing.expectEqualStrings("solo.eth", solo.?.name.?);
    // Multi-row namehash: absent — handler falls back to the point query.
    try std.testing.expectEqual(@as(?(?*const models.Name), null), ctx.lookupDomain(nh(2)));
    // Zero rows: batched "no row" sentinel.
    const missing = ctx.lookupDomain(nh(3)) orelse return error.ExpectedBatched;
    try std.testing.expectEqual(@as(?*const models.Name, null), missing);
    // Unrequested namehash: never invented.
    try std.testing.expectEqual(@as(?(?*const models.Name), null), ctx.lookupDomain(nh(9)));

    // Repeat priming with overlap must not leak (testing.allocator enforces).
    ctx.populateDomains(&test_db, &page);
    const again = ctx.lookupDomain(nh(1)) orelse return error.ExpectedBatched;
    try std.testing.expectEqualStrings("solo.eth", again.?.name.?);
}

// ============================================================================
// Complex Scenario Tests for N+1 Query Problem and Memory Management
// ============================================================================
