/// Domain-related GraphQL resolvers
/// - resolveDomain: Single domain lookup by id
/// - resolveDomains: List domains with filters
/// - resolveDomainConnection: Cursor-based pagination for domains
const std = @import("std");
const common = @import("common.zig");
const db = common.db;
const models = common.models;
const Address = common.Address;
const parser = common.parser;
const pagination = common.pagination;
const builders = @import("../builders/builders.zig");
const at_block_mod = @import("../../storage/at_block.zig");
const loaders = common.loaders;
const namehash = common.namehash_fn;
const Hash = common.Hash;
const NestedContext = builders.NestedContext;

/// Resolve a domain id (either a name like "alice.eth" or a 32-byte namehash hex like
/// "0x...64 hex chars") to a namehash. Mirrors the schema doc on `domain(id:)` which
/// promises both forms work.
fn resolveDomainId(allocator: std.mem.Allocator, id: []const u8) !Hash {
    if (id.len == 66 and std.mem.startsWith(u8, id, "0x")) {
        var all_hex = true;
        for (id[2..]) |c| {
            if (!std.ascii.isHex(c)) {
                all_hex = false;
                break;
            }
        }
        if (all_hex) return Hash.fromHex(id);
    }
    return namehash(allocator, id);
}

pub fn mapDomainOrderBy(order_by: ?[]const u8) db.NameSortField {
    const field_name = order_by orelse return .created_at;
    if (std.mem.eql(u8, field_name, "name")) return .name;
    if (std.mem.eql(u8, field_name, "createdAt")) return .created_at;
    // Grace-inclusive, matching the expiryDate value and expiryDate_* filters —
    // a raw-expiry sort would disagree with displayed values by up to 90d.
    if (std.mem.eql(u8, field_name, "expiryDate")) return .expiry_effective;
    if (std.mem.eql(u8, field_name, "registrationDate")) return .registered_at;
    return .created_at;
}

/// Parsed `where:` arguments for the Domain queries.
///
/// `resolveDomains` and `resolveDomainConnection` both accept the same
/// `DomainFilter` input object. Before this helper, each one had its own
/// ~140-line parsing block that drifted between them every time a filter
/// was added (and forced every new filter to be wired in twice). This struct
/// centralises both the slot layout AND the parsing so they stay in sync by
/// construction.
const ParsedDomainFilter = struct {
    token_id: ?[]const u8 = null,
    canonical_id: ?[]const u8 = null,
    registry: ?Address = null,
    name: ?[]const u8 = null,
    name_in: ?[][]const u8 = null,
    name_not: ?[]const u8 = null,
    name_not_in: ?[][]const u8 = null,
    name_contains: ?[]const u8 = null,
    name_contains_nocase: ?[]const u8 = null,
    name_not_contains: ?[]const u8 = null,
    name_starts_with: ?[]const u8 = null,
    name_starts_with_nocase: ?[]const u8 = null,
    name_ends_with: ?[]const u8 = null,
    name_ends_with_nocase: ?[]const u8 = null,
    label_name: ?[]const u8 = null,
    label_name_not: ?[]const u8 = null,
    label_name_in: ?[][]const u8 = null,
    label_name_not_in: ?[][]const u8 = null,
    label_name_contains: ?[]const u8 = null,
    label_name_contains_nocase: ?[]const u8 = null,
    label_name_not_contains: ?[]const u8 = null,
    label_name_starts_with: ?[]const u8 = null,
    label_name_starts_with_nocase: ?[]const u8 = null,
    label_name_ends_with: ?[]const u8 = null,
    label_name_ends_with_nocase: ?[]const u8 = null,
    owner: ?Address = null,
    owner_in: ?[]Address = null,
    owner_not: ?Address = null,
    owner_not_in: ?[]Address = null,
    resolved_address: ?Address = null,
    resolver: ?Address = null,
    has_subdomains: ?bool = null,
    subdomain_count_gt: ?i64 = null,
    subdomain_count_lt: ?i64 = null,
    expiry_gt: ?i64 = null,
    expiry_gte: ?i64 = null,
    expiry_lt: ?i64 = null,
    expiry_lte: ?i64 = null,
    expiry_date_gt: ?i64 = null,
    expiry_date_gte: ?i64 = null,
    expiry_date_lt: ?i64 = null,
    expiry_date_lte: ?i64 = null,
    migrated: ?bool = null,
    include_unreachable: ?bool = null,
    is_normalized: ?bool = null,
    include_unnormalized: ?bool = null,
    /// Subgraph-style boolean composition (`where: { and: [...], or: [...] }`).
    /// Each element is a nested DomainFilter, parsed recursively.
    and_filters: ?[]ParsedDomainFilter = null,
    or_filters: ?[]ParsedDomainFilter = null,

    /// Frees the heap-allocated slice fields (`*_in` lists + nested and/or groups).
    /// Scalar fields point into the caller-owned GraphQL arg buffer and need no
    /// cleanup. (Request allocations are arena-backed, so this is belt-and-braces.)
    pub fn deinit(self: *ParsedDomainFilter, allocator: std.mem.Allocator) void {
        if (self.name_in) |s| allocator.free(s);
        if (self.name_not_in) |s| allocator.free(s);
        if (self.label_name_in) |s| allocator.free(s);
        if (self.label_name_not_in) |s| allocator.free(s);
        if (self.owner_in) |s| allocator.free(s);
        if (self.owner_not_in) |s| allocator.free(s);
        if (self.and_filters) |group| {
            for (group) |*c| c.deinit(allocator);
            allocator.free(group);
        }
        if (self.or_filters) |group| {
            for (group) |*c| c.deinit(allocator);
            allocator.free(group);
        }
    }
};

/// Parse the `where:` arg of a domains/domainConnection query into the
/// `ParsedDomainFilter` struct. Unknown args were already rejected by the
/// schema validator at parse time, so the `or`-chain at the bottom discards
/// match-misses silently.
fn parseDomainWhere(field: *const parser.Field, allocator: std.mem.Allocator) !ParsedDomainFilter {
    const where_args = common.getObjectArg(field, "where") orelse return ParsedDomainFilter{};
    return parseWhereArgs(where_args, allocator);
}

/// Parse a DomainFilter argument list — the top-level `where:` object or a nested
/// `and`/`or` element — into a `ParsedDomainFilter`. Recursive for the boolean groups.
fn parseWhereArgs(where_args: []const parser.Argument, allocator: std.mem.Allocator) anyerror!ParsedDomainFilter {
    var out = ParsedDomainFilter{};
    errdefer out.deinit(allocator);

    for (where_args) |a| {
        // Boolean composition: `and` / `or` are lists of nested DomainFilters (subgraph parity).
        if ((std.mem.eql(u8, a.name, "and") or std.mem.eql(u8, a.name, "or")) and a.value == .list) {
            const is_and = std.mem.eql(u8, a.name, "and");
            var group: std.ArrayList(ParsedDomainFilter) = .empty;
            errdefer {
                for (group.items) |*c| c.deinit(allocator);
                group.deinit(allocator);
            }
            for (a.value.list) |item| {
                if (item == .object) {
                    try group.append(allocator, try parseWhereArgs(item.object, allocator));
                }
            }
            const slice = try group.toOwnedSlice(allocator);
            if (is_and) {
                out.and_filters = slice;
            } else {
                out.or_filters = slice;
            }
            continue;
        }
        // List-typed args allocate via the shared helpers in common.zig.
        if (std.mem.eql(u8, a.name, "owner_in")) {
            if (try common.parseAddressListArg(a, allocator)) |v| out.owner_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "owner_not_in")) {
            if (try common.parseAddressListArg(a, allocator)) |v| out.owner_not_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "name_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.name_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "name_not_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.name_not_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "labelName_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.label_name_in = v;
            continue;
        }
        if (std.mem.eql(u8, a.name, "labelName_not_in")) {
            if (try common.parseStringListArg(a, allocator)) |v| out.label_name_not_in = v;
            continue;
        }
        // `owner_:` nested AccountFilter — subgraph parity — translates to owner / owner_in.
        if (std.mem.eql(u8, a.name, "owner_") and a.value == .object) {
            for (a.value.object) |nested| {
                if (std.mem.eql(u8, nested.name, "id") and nested.value == .string) {
                    out.owner = Address.fromHex(nested.value.string) catch return error.InvalidAddress;
                } else if (std.mem.eql(u8, nested.name, "id_in")) {
                    if (try common.parseAddressListArg(nested, allocator)) |v| out.owner_in = v;
                }
            }
            continue;
        }

        _ = common.matchStringArg(a, "name", &out.name) or
            common.matchStringArg(a, "name_not", &out.name_not) or
            common.matchStringArg(a, "name_contains", &out.name_contains) or
            common.matchStringArg(a, "name_contains_nocase", &out.name_contains_nocase) or
            common.matchStringArg(a, "name_not_contains", &out.name_not_contains) or
            common.matchStringArg(a, "name_starts_with", &out.name_starts_with) or
            common.matchStringArg(a, "name_starts_with_nocase", &out.name_starts_with_nocase) or
            common.matchStringArg(a, "name_ends_with", &out.name_ends_with) or
            common.matchStringArg(a, "name_ends_with_nocase", &out.name_ends_with_nocase) or
            common.matchStringArg(a, "labelName", &out.label_name) or
            common.matchStringArg(a, "labelName_not", &out.label_name_not) or
            common.matchStringArg(a, "labelName_contains", &out.label_name_contains) or
            common.matchStringArg(a, "labelName_contains_nocase", &out.label_name_contains_nocase) or
            common.matchStringArg(a, "labelName_not_contains", &out.label_name_not_contains) or
            common.matchStringArg(a, "labelName_starts_with", &out.label_name_starts_with) or
            common.matchStringArg(a, "labelName_starts_with_nocase", &out.label_name_starts_with_nocase) or
            common.matchStringArg(a, "labelName_ends_with", &out.label_name_ends_with) or
            common.matchStringArg(a, "labelName_ends_with_nocase", &out.label_name_ends_with_nocase) or
            (try common.matchAddressArg(a, "owner", &out.owner)) or
            (try common.matchAddressArg(a, "owner_not", &out.owner_not)) or
            (try common.matchAddressArg(a, "resolvedAddress", &out.resolved_address)) or
            common.matchStringArg(a, "tokenId", &out.token_id) or
            common.matchStringArg(a, "canonicalId", &out.canonical_id) or
            (try common.matchAddressArg(a, "registry", &out.registry)) or
            (try common.matchAddressArg(a, "resolver", &out.resolver)) or
            common.matchBoolArg(a, "hasSubdomains", &out.has_subdomains) or
            common.matchIntArg(a, "subdomainCount_gt", &out.subdomain_count_gt) or
            common.matchIntArg(a, "subdomainCount_lt", &out.subdomain_count_lt) or
            common.matchIntArg(a, "expiry_gt", &out.expiry_gt) or
            common.matchIntArg(a, "expiry_gte", &out.expiry_gte) or
            common.matchIntArg(a, "expiry_lt", &out.expiry_lt) or
            common.matchIntArg(a, "expiry_lte", &out.expiry_lte) or
            // Subgraph-parity: expiryDate_* compares the grace-inclusive value
            // (effectiveDomainExpiry semantics), unlike the bare expiry_* slots.
            common.matchIntArg(a, "expiryDate_gt", &out.expiry_date_gt) or
            common.matchIntArg(a, "expiryDate_gte", &out.expiry_date_gte) or
            common.matchIntArg(a, "expiryDate_lt", &out.expiry_date_lt) or
            common.matchIntArg(a, "expiryDate_lte", &out.expiry_date_lte) or
            common.matchBoolArg(a, "isMigrated", &out.migrated) or
            common.matchBoolArg(a, "includeUnreachable", &out.include_unreachable) or
            common.matchBoolArg(a, "isNormalized", &out.is_normalized) or
            common.matchBoolArg(a, "includeUnnormalized", &out.include_unnormalized);
    }
    return out;
}

/// Map a parsed DomainFilter (one node) to a storage `NameFilters`, recursively
/// translating the `and`/`or` groups. Allocations are request-arena-backed.
/// Normalize a client-supplied u256 token/canonical id to the stored column
/// format (0x + 64 lowercase hex). Accepts 0x-hex of any length or a decimal
/// string — marketplaces send ERC-1155 token ids as decimals. Rejects
/// non-numeric input so a typo'd filter errors instead of silently matching
/// nothing.
fn normalizeU256Id(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const v = std.fmt.parseInt(u256, raw, 0) catch return error.InvalidArgument;
    return std.fmt.allocPrint(allocator, "0x{x:0>64}", .{v});
}

fn toNameFilters(p: *const ParsedDomainFilter, allocator: std.mem.Allocator) anyerror!db.NameFilters {
    return db.NameFilters{
        .token_id = if (p.token_id) |v| try normalizeU256Id(allocator, v) else null,
        .canonical_id = if (p.canonical_id) |v| try normalizeU256Id(allocator, v) else null,
        .registry = p.registry,
        .owner = p.owner,
        .owner_in = p.owner_in,
        .owner_not = p.owner_not,
        .owner_not_in = p.owner_not_in,
        .name = p.name,
        .name_in = p.name_in,
        .name_not = p.name_not,
        .name_not_in = p.name_not_in,
        .name_contains = p.name_contains,
        .name_contains_nocase = p.name_contains_nocase,
        .name_not_contains = p.name_not_contains,
        .name_starts_with = p.name_starts_with,
        .name_starts_with_nocase = p.name_starts_with_nocase,
        .name_ends_with = p.name_ends_with,
        .name_ends_with_nocase = p.name_ends_with_nocase,
        .label_name = p.label_name,
        .label_name_not = p.label_name_not,
        .label_name_in = p.label_name_in,
        .label_name_not_in = p.label_name_not_in,
        .label_name_contains = p.label_name_contains,
        .label_name_contains_nocase = p.label_name_contains_nocase,
        .label_name_not_contains = p.label_name_not_contains,
        .label_name_starts_with = p.label_name_starts_with,
        .label_name_starts_with_nocase = p.label_name_starts_with_nocase,
        .label_name_ends_with = p.label_name_ends_with,
        .label_name_ends_with_nocase = p.label_name_ends_with_nocase,
        .expiry_gt = p.expiry_gt,
        .expiry_gte = p.expiry_gte,
        .expiry_date_gt = p.expiry_date_gt,
        .expiry_date_gte = p.expiry_date_gte,
        .expiry_date_lt = p.expiry_date_lt,
        .expiry_date_lte = p.expiry_date_lte,
        .expiry_lt = p.expiry_lt,
        .expiry_lte = p.expiry_lte,
        .resolved_address = p.resolved_address,
        .resolver = p.resolver,
        .migrated = p.migrated,
        .has_subdomains = p.has_subdomains,
        .subdomain_count_gt = p.subdomain_count_gt,
        .subdomain_count_lt = p.subdomain_count_lt,
        .include_unreachable = p.include_unreachable orelse false,
        .include_unnormalized = p.include_unnormalized orelse false,
        .is_normalized = p.is_normalized,
        .and_group = try mapFilterGroup(p.and_filters, allocator),
        .or_group = try mapFilterGroup(p.or_filters, allocator),
    };
}

/// Map a parsed `and`/`or` group to a slice of storage `NameFilters` (or null).
fn mapFilterGroup(group: ?[]const ParsedDomainFilter, allocator: std.mem.Allocator) anyerror!?[]const db.NameFilters {
    const children = group orelse return null;
    const arr = try allocator.alloc(db.NameFilters, children.len);
    for (children, 0..) |*c, i| arr[i] = try toNameFilters(c, allocator);
    return arr;
}

const ResolverRecordWants = struct {
    addr: bool = false,
    contenthash: bool = false,
    text_keys: bool = false,
    coin_types: bool = false,
    /// `resolver { domain { … } }` — the resolver → domain back-reference.
    domain: bool = false,
    /// The record-list / single-value families (addresses, pubkey, abis,
    /// reverseName, interfaces, version, aliases).
    families: loaders.LoaderContext.ResolverFamilyWants = .{},
    /// `resolver { … }` or `resolvedAddress` is selected at all, so the
    /// effective (possibly inherited) resolver is needed per row.
    resolver_selected: bool = false,

    fn anyRecords(self: ResolverRecordWants) bool {
        return self.addr or self.contenthash or self.text_keys or self.coin_types or self.domain or self.families.any();
    }
};

/// Which batchable fields a Resolver-level selection set reads.
fn scanResolverSelections(resolver_selections: []const parser.Field, want: *ResolverRecordWants) void {
    for (resolver_selections) |*sub| {
        if (std.mem.eql(u8, sub.name, "addr")) want.addr = true;
        if (std.mem.eql(u8, sub.name, "contentHash")) want.contenthash = true;
        if (std.mem.eql(u8, sub.name, "texts")) want.text_keys = true;
        if (std.mem.eql(u8, sub.name, "coinTypes")) want.coin_types = true;
        if (std.mem.eql(u8, sub.name, "domain")) want.domain = true;
        if (std.mem.eql(u8, sub.name, "addresses")) want.families.addresses = true;
        if (std.mem.eql(u8, sub.name, "pubkey")) want.families.pubkey = true;
        if (std.mem.eql(u8, sub.name, "abis")) want.families.abis = true;
        if (std.mem.eql(u8, sub.name, "reverseName")) want.families.reverse_name = true;
        if (std.mem.eql(u8, sub.name, "interfaces")) want.families.interfaces = true;
        if (std.mem.eql(u8, sub.name, "version")) want.families.version = true;
        if (std.mem.eql(u8, sub.name, "aliases")) want.families.aliases = true;
    }
}

/// Which batchable resolver fields a `domains` selection reads: `resolvedAddress`
/// or `resolver{ addr }` -> addr, plus everything scanResolverSelections finds
/// under `resolver { ... }`.
fn wantsResolverRecords(selections: []const parser.Field) ResolverRecordWants {
    var want = ResolverRecordWants{};
    for (selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "resolvedAddress")) {
            want.addr = true;
            want.resolver_selected = true;
        } else if (std.mem.eql(u8, sel.name, "resolver")) {
            want.resolver_selected = true;
            scanResolverSelections(sel.selections, &want);
        }
    }
    return want;
}

fn findSelection(selections: []const parser.Field, name: []const u8) ?*const parser.Field {
    for (selections) |*sel| {
        if (std.mem.eql(u8, sel.name, name)) return sel;
    }
    return null;
}

/// Collect the distinct `text(key:"...")` keys in a Resolver-level selection
/// set, so they can be batch-prefetched. Deduped (aliases of the same key
/// batch once).
fn collectResolverTextKeyArgs(resolver_selections: []const parser.Field, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    for (resolver_selections) |*sub| {
        if (!std.mem.eql(u8, sub.name, "text")) continue;
        for (sub.arguments) |arg| {
            if (!std.mem.eql(u8, arg.name, "key") or arg.value != .string) continue;
            const k = arg.value.string;
            var seen = false;
            for (list.items) |ex| {
                if (std.mem.eql(u8, ex, k)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try list.append(allocator, k);
        }
    }
}

fn collectTextKeys(selections: []const parser.Field, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    for (selections) |*sel| {
        if (!std.mem.eql(u8, sel.name, "resolver")) continue;
        try collectResolverTextKeyArgs(sel.selections, list, allocator);
    }
}

/// Page-level prefetch for a list of Domain rows: every nested field the
/// selection reads that would otherwise cost one query per row is loaded
/// into the request loader in one batch per field, and nested Domain
/// selections (`parent { … }`, `subdomains { … }`, `resolver { domain { … } }`)
/// recurse so their own nested reads are batched too. Best-effort
/// throughout: any failure leaves the handlers on their point-query paths.
pub fn prefetchResolverRecords(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: ?*anyopaque, page: []models.Name, selections: []const parser.Field) void {
    prefetchDomainPageEvents(database, allocator, loaders_ptr, page, selections);
    if (page.len == 0) return;
    const lp = loaders_ptr orelse return;
    const lc: *loaders.LoaderContext = @ptrCast(@alignCast(lp));
    prefetchDomainNestedFields(database, allocator, lc, page, selections);

    const want = wantsResolverRecords(selections);
    var text_keys: std.ArrayList([]const u8) = .empty;
    defer text_keys.deinit(allocator);
    collectTextKeys(selections, &text_keys, allocator) catch {};
    if (!want.resolver_selected) return;

    // The ENSIP-10 walk for every row without its own resolver, memoized so
    // the record handlers (and the resolver handler itself) read it back
    // instead of walking per row.
    lc.populateInheritedResolvers(database, page);
    if (!want.anyRecords() and text_keys.items.len == 0) return;

    const resolvers_buf = allocator.alloc(Address, page.len) catch return;
    defer allocator.free(resolvers_buf);
    const namehashes_buf = allocator.alloc(Hash, page.len) catch return;
    defer allocator.free(namehashes_buf);
    for (page, 0..) |*n, i| {
        // Compute the SAME effective resolver the record handlers will query with,
        // so the batch keys match; the composite key makes any divergence a safe miss.
        resolvers_buf[i] = builders.effectiveResolverWith(database, lp, n) catch n.resolver;
        namehashes_buf[i] = n.namehash;
    }
    if (want.addr or want.contenthash) {
        lc.populateResolverRecords(database, resolvers_buf, namehashes_buf, want.addr, want.contenthash);
    }
    if (text_keys.items.len > 0) {
        lc.populateTextRecords(database, resolvers_buf, namehashes_buf, text_keys.items);
    }
    if (want.text_keys) {
        lc.populateTextKeyLists(database, resolvers_buf, namehashes_buf);
    }
    if (want.coin_types) {
        lc.populateCoinTypeLists(database, resolvers_buf, namehashes_buf);
    }
    if (want.families.any()) {
        lc.populateResolverFamilies(database, resolvers_buf, namehashes_buf, want.families);
    }
    if (want.domain) {
        const resolver_sel = findSelection(selections, "resolver") orelse return;
        const domain_sel = findSelection(resolver_sel.selections, "domain") orelse return;
        prefetchResolverDomains(database, allocator, lp, lc, resolvers_buf, domain_sel.selections);
    }
}

/// `resolver { domain { … } }`: one batch for the page's distinct effective
/// resolvers, then the batched rows' own nested selections.
fn prefetchResolverDomains(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: *anyopaque, lc: *loaders.LoaderContext, resolvers: []const Address, domain_selections: []const parser.Field) void {
    var unique: std.ArrayList(Address) = .empty;
    defer unique.deinit(allocator);
    var seen = std.AutoHashMap([20]u8, void).init(allocator);
    defer seen.deinit();
    for (resolvers) |r| {
        if (r.isZero()) continue;
        const gop = seen.getOrPut(r.bytes) catch return;
        if (gop.found_existing) continue;
        unique.append(allocator, r) catch return;
    }
    if (unique.items.len == 0) return;
    lc.populateDomainsByResolver(database, unique.items);

    var page_rows: std.ArrayList(models.Name) = .empty;
    defer page_rows.deinit(allocator);
    for (unique.items) |r| {
        const batched = lc.lookupDomainByResolver(r) orelse continue;
        const row = batched orelse continue;
        page_rows.append(allocator, row.*) catch return;
    }
    if (page_rows.items.len == 0) return;
    prefetchResolverRecords(database, allocator, loaders_ptr, page_rows.items, domain_selections);
}

/// The Domain-level nested fields that read per row: parent, subregistry,
/// the three counts, subdomains / subdomainConnection pages and
/// eventsConnection. Each is batched only when selected.
fn prefetchDomainNestedFields(database: *db.Database, allocator: std.mem.Allocator, lc: *loaders.LoaderContext, page: []models.Name, selections: []const parser.Field) void {
    if (findSelection(selections, "parent")) |parent_sel| {
        prefetchParents(database, allocator, lc, page, parent_sel.selections);
    }
    if (findSelection(selections, "subregistry") != null) {
        lc.populateSubregistries(database, page);
    }
    if (findSelection(selections, "subdomainCount") != null or findSelection(selections, "subdomainsCount") != null) {
        lc.populateSubdomainCounts(database, page);
    }
    if (findSelection(selections, "eventsCount") != null) {
        lc.populateEventCounts(database, page);
    }
    if (findSelection(selections, "roleHolderCount") != null) {
        lc.populateRoleHolderCounts(database, page);
    }
    if (findSelection(selections, "subdomains")) |sub_sel| {
        const pg = common.parsePagination(sub_sel, 10) catch return;
        prefetchSubdomainPages(database, allocator, lc, page, pg.skip, pg.first, sub_sel.selections);
    } else if (findSelection(selections, "subdomainConnection")) |conn_sel| {
        // Mirrors domainSubdomainConnectionHandler: page (0, limit + 1) plus
        // the count when totalCount is selected.
        const limit: u32 = @min((common.parsePagination(conn_sel, 10) catch return).first, 100);
        if (findSelection(conn_sel.selections, "totalCount") != null) lc.populateSubdomainCounts(database, page);
        const node_selections = connectionNodeSelections(conn_sel);
        prefetchSubdomainPages(database, allocator, lc, page, 0, limit + 1, node_selections);
    }
    if (findSelection(selections, "events") == null) {
        if (findSelection(selections, "eventsConnection")) |conn_sel| {
            // Mirrors domainEventsConnectionHandler's filter exactly; skipped
            // when `events` is also selected (the loader holds one page shape).
            const limit: u32 = @min((common.parsePagination(conn_sel, 10) catch return).first, 100);
            if (findSelection(conn_sel.selections, "totalCount") != null) lc.populateEventCounts(database, page);
            const namehashes = allocator.alloc(Hash, page.len) catch return;
            defer allocator.free(namehashes);
            for (page, 0..) |*n, i| namehashes[i] = n.namehash;
            lc.populateDomainEvents(database, namehashes, .{ .limit = limit + 1 });
        }
    }
}

fn connectionNodeSelections(conn_sel: *const parser.Field) []const parser.Field {
    const edges = findSelection(conn_sel.selections, "edges") orelse return &[_]parser.Field{};
    const node = findSelection(edges.selections, "node") orelse return &[_]parser.Field{};
    return node.selections;
}

/// `parent { … }`: one IN-list domains query for the page's distinct parent
/// namehashes (the handler's getNameByNamehash mirror), then the parents'
/// own nested selections.
fn prefetchParents(database: *db.Database, allocator: std.mem.Allocator, lc: *loaders.LoaderContext, page: []models.Name, parent_selections: []const parser.Field) void {
    var parents: std.ArrayList(Hash) = .empty;
    defer parents.deinit(allocator);
    var seen = std.AutoHashMap(Hash, void).init(allocator);
    defer seen.deinit();
    for (page) |*n| {
        if (n.parent_namehash.isZero()) continue;
        const gop = seen.getOrPut(n.parent_namehash) catch return;
        if (gop.found_existing) continue;
        parents.append(allocator, n.parent_namehash) catch return;
    }
    if (parents.items.len == 0) return;
    lc.populateDomains(database, parents.items);

    var parent_rows: std.ArrayList(models.Name) = .empty;
    defer parent_rows.deinit(allocator);
    for (parents.items) |nh| {
        const batched = lc.lookupDomain(nh) orelse continue;
        const row = batched orelse continue;
        parent_rows.append(allocator, row.*) catch return;
    }
    if (parent_rows.items.len == 0) return;
    prefetchResolverRecords(database, allocator, @ptrCast(lc), parent_rows.items, parent_selections);
}

/// `subdomains(first, skip) { … }`: one windowed IN query for the page's
/// parents, then the subdomain rows' own nested selections.
fn prefetchSubdomainPages(database: *db.Database, allocator: std.mem.Allocator, lc: *loaders.LoaderContext, page: []models.Name, skip: u32, first: u32, sub_selections: []const parser.Field) void {
    lc.populateSubdomainPages(database, page, skip, first);
    var sub_rows: std.ArrayList(models.Name) = .empty;
    defer sub_rows.deinit(allocator);
    for (page) |*n| {
        const parent_name = n.name orelse continue;
        const batched = lc.lookupSubdomainPage(parent_name, skip, first) orelse continue;
        for (batched) |row| sub_rows.append(allocator, row) catch return;
    }
    if (sub_rows.items.len == 0) return;
    prefetchResolverRecords(database, allocator, @ptrCast(lc), sub_rows.items, sub_selections);
}

/// Page-batch a Domain list's nested `events(...)` field: one per-namehash
/// window query for the page instead of one query per row, plus one domains
/// query for the page so `events { domain { … } }` (whose namehash is the
/// enclosing domain's) resolves from memory. Best-effort: any failure
/// leaves the loader unprimed and the handlers fall back to point queries.
fn prefetchDomainPageEvents(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: ?*anyopaque, page: []models.Name, selections: []const parser.Field) void {
    if (page.len == 0) return;
    const lp = loaders_ptr orelse return;
    const lc: *loaders.LoaderContext = @ptrCast(@alignCast(lp));
    const events_sel: *const parser.Field = blk: {
        for (selections) |*sel| {
            if (std.mem.eql(u8, sel.name, "events")) break :blk sel;
        }
        return;
    };
    var parsed = builders.parseDomainEventsFilter(events_sel, allocator) catch return;
    defer parsed.deinit(allocator);

    const namehashes = allocator.alloc(Hash, page.len) catch return;
    defer allocator.free(namehashes);
    for (page, 0..) |*n, i| namehashes[i] = n.namehash;
    // One IN-list query rather than seeding the page's own rows: a namehash
    // with a v1/v2 twin must resolve exactly as the point query would, which
    // populateDomains guarantees by refusing to cache ambiguous rows.
    lc.populateDomains(database, namehashes);
    lc.populateDomainEvents(database, namehashes, parsed.opts);
}

/// Record prefetch for a page whose rows ARE (resolver, namehash) pairs — the
/// top-level resolvers list. Same population as prefetchResolverRecords, but
/// the selections are Resolver-level and the pair is the row itself, so no
/// effective-resolver walk is involved: the loader keys match what each row's
/// handlers query with exactly. Best-effort.
pub fn prefetchRecordsForResolverPage(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: ?*anyopaque, resolvers_page: []const Address, namehashes_page: []const Hash, resolver_selections: []const parser.Field) void {
    var want = ResolverRecordWants{};
    scanResolverSelections(resolver_selections, &want);
    var text_keys: std.ArrayList([]const u8) = .empty;
    defer text_keys.deinit(allocator);
    collectResolverTextKeyArgs(resolver_selections, &text_keys, allocator) catch {};
    if (!want.addr and !want.contenthash and !want.text_keys and !want.coin_types and text_keys.items.len == 0) return;
    const lp = loaders_ptr orelse return;
    const lc: *loaders.LoaderContext = @ptrCast(@alignCast(lp));

    if (want.addr or want.contenthash) {
        lc.populateResolverRecords(database, resolvers_page, namehashes_page, want.addr, want.contenthash);
    }
    if (text_keys.items.len > 0) {
        lc.populateTextRecords(database, resolvers_page, namehashes_page, text_keys.items);
    }
    if (want.text_keys) {
        lc.populateTextKeyLists(database, resolvers_page, namehashes_page);
    }
    if (want.coin_types) {
        lc.populateCoinTypeLists(database, resolvers_page, namehashes_page);
    }
}

/// Page-level prefetch for event-shaped lists that resolve `domain { … }` per
/// row (registrations, domain-events): one IN-list domains query into the
/// request loader (multi-row namehashes excluded — the point query keeps its
/// exact semantics), then the same resolver-record/text prefetch the domains
/// list gets. Per-row handlers then serve everything from memory. Best-effort
/// throughout: any failure just leaves handlers on their point-query paths.
pub fn prefetchDomainsForEventPage(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: ?*anyopaque, events: []const models.Event, node_selections: []const parser.Field) void {
    const lp = loaders_ptr orelse return;
    const lc: *loaders.LoaderContext = @ptrCast(@alignCast(lp));

    const domain_sel: *const parser.Field = blk: {
        for (node_selections) |*sel| {
            if (std.mem.eql(u8, sel.name, "domain")) break :blk sel;
        }
        return;
    };

    var namehashes: std.ArrayList(Hash) = .empty;
    defer namehashes.deinit(allocator);
    var seen = std.AutoHashMap(Hash, void).init(allocator);
    defer seen.deinit();
    for (events) |*ev| {
        const nh = ev.namehash orelse continue;
        // Dedupe: a repeated namehash straddling two IN-list chunks would look
        // like a multi-row namehash and get evicted from the batch (perf loss,
        // not a correctness issue — but why pay it).
        const gop = seen.getOrPut(nh) catch return;
        if (gop.found_existing) continue;
        namehashes.append(allocator, nh) catch return;
    }
    if (namehashes.items.len == 0) return;
    lc.populateDomains(database, namehashes.items);

    // Shallow copies of the loader-owned rows for the record prefetch — the
    // strings stay loader-owned; nothing here frees them.
    var page_rows: std.ArrayList(models.Name) = .empty;
    defer page_rows.deinit(allocator);
    for (namehashes.items) |nh| {
        const batched = lc.lookupDomain(nh) orelse continue;
        const row = batched orelse continue;
        page_rows.append(allocator, row.*) catch return;
    }
    if (page_rows.items.len == 0) return;
    prefetchResolverRecords(database, allocator, loaders_ptr, page_rows.items, domain_sel.selections);
}

/// Page-level prefetch for accounts lists: one windowed query loads every
/// account's nested `domains` page into the request loader, then the shared
/// resolver-record/text prefetch primes those domains' nested reads. The
/// per-account handler serves it all from memory; absent entries fall back
/// to the original point queries. Best-effort throughout.
pub fn prefetchDomainsForAccountsPage(database: *db.Database, allocator: std.mem.Allocator, loaders_ptr: ?*anyopaque, accounts: []const db.Account, account_selections: []const parser.Field) void {
    const lp = loaders_ptr orelse return;
    const lc: *loaders.LoaderContext = @ptrCast(@alignCast(lp));

    const domains_sel: *const parser.Field = blk: {
        for (account_selections) |*sel| {
            if (std.mem.eql(u8, sel.name, "domains")) break :blk sel;
        }
        return;
    };
    const page = common.parsePagination(domains_sel, 10) catch return;

    var owners: std.ArrayList(Address) = .empty;
    defer owners.deinit(allocator);
    for (accounts) |acct| {
        const addr = Address.fromHex(acct.address) catch continue;
        owners.append(allocator, addr) catch return;
    }
    if (owners.items.len == 0) return;
    lc.populateAccountDomains(database, owners.items, page.skip, page.first);

    // Prime the domains' nested resolver records/texts from the batched rows
    // (shallow copies; strings stay loader-owned).
    var page_rows: std.ArrayList(models.Name) = .empty;
    defer page_rows.deinit(allocator);
    for (owners.items) |owner| {
        var owner_buf: [42]u8 = undefined;
        const owner_hex = owner.toHexBuf(&owner_buf);
        const batched = lc.lookupAccountDomains(owner_hex, page.skip, page.first) orelse continue;
        for (batched) |row| page_rows.append(allocator, row) catch return;
    }
    if (page_rows.items.len == 0) return;
    prefetchResolverRecords(database, allocator, loaders_ptr, page_rows.items, domains_sel.selections);
}

pub fn resolveDomains(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    const page = try common.parsePagination(field, 100);
    const first = page.first;
    const skip = page.skip;

    // Parse `where` filter via the shared helper.
    var parsed = try parseDomainWhere(field, allocator);
    defer parsed.deinit(allocator);
    const filter_name = parsed.name;
    const filter_name_in = parsed.name_in;
    const filter_name_not = parsed.name_not;
    const filter_name_not_in = parsed.name_not_in;
    const filter_name_contains = parsed.name_contains;
    const filter_name_contains_nocase = parsed.name_contains_nocase;
    const filter_name_not_contains = parsed.name_not_contains;
    const filter_name_starts_with = parsed.name_starts_with;
    const filter_name_starts_with_nocase = parsed.name_starts_with_nocase;
    const filter_name_ends_with = parsed.name_ends_with;
    const filter_name_ends_with_nocase = parsed.name_ends_with_nocase;
    const filter_label_name = parsed.label_name;
    const filter_label_name_not = parsed.label_name_not;
    const filter_label_name_in = parsed.label_name_in;
    const filter_label_name_not_in = parsed.label_name_not_in;
    const filter_label_name_contains = parsed.label_name_contains;
    const filter_label_name_contains_nocase = parsed.label_name_contains_nocase;
    const filter_label_name_not_contains = parsed.label_name_not_contains;
    const filter_label_name_starts_with = parsed.label_name_starts_with;
    const filter_label_name_starts_with_nocase = parsed.label_name_starts_with_nocase;
    const filter_label_name_ends_with = parsed.label_name_ends_with;
    const filter_label_name_ends_with_nocase = parsed.label_name_ends_with_nocase;
    const filter_owner = parsed.owner;
    const filter_owner_in = parsed.owner_in;
    const filter_owner_not = parsed.owner_not;
    const filter_owner_not_in = parsed.owner_not_in;
    const filter_resolved_address = parsed.resolved_address;
    const filter_resolver = parsed.resolver;
    const filter_has_subdomains = parsed.has_subdomains;
    const filter_subdomain_count_gt = parsed.subdomain_count_gt;
    const filter_subdomain_count_lt = parsed.subdomain_count_lt;
    const filter_expiry_gt = parsed.expiry_gt;
    const filter_expiry_gte = parsed.expiry_gte;
    const filter_expiry_lt = parsed.expiry_lt;
    const filter_expiry_lte = parsed.expiry_lte;
    const filter_expiry_date_gt = parsed.expiry_date_gt;
    const filter_expiry_date_gte = parsed.expiry_date_gte;
    const filter_expiry_date_lt = parsed.expiry_date_lt;
    const filter_expiry_date_lte = parsed.expiry_date_lte;
    const filter_migrated = parsed.migrated;

    const include_unreachable = parsed.include_unreachable orelse false;
    const include_unnormalized = parsed.include_unnormalized orelse false;

    const order_by = parser.getStringArg(field, "orderBy", null);
    const order_dir_parsed = common.parseOrderDirection(field, db.OrderDir, .desc);

    // Get names from database
    // Optimization: if ONLY name filter is set (no other filters), use direct namehash lookup (O(1))
    // If additional filters are present, fall through to getFilteredNames so all filters apply correctly
    const no_label_filters = filter_label_name == null and filter_label_name_not == null and
        filter_label_name_in == null and filter_label_name_not_in == null and
        filter_label_name_contains == null and filter_label_name_contains_nocase == null and
        filter_label_name_not_contains == null and
        filter_label_name_starts_with == null and filter_label_name_starts_with_nocase == null and
        filter_label_name_ends_with == null and filter_label_name_ends_with_nocase == null;

    const only_name_filter = filter_name != null and
        parsed.token_id == null and parsed.canonical_id == null and parsed.registry == null and
        filter_name_not == null and filter_name_not_in == null and
        filter_owner == null and filter_owner_in == null and
        filter_owner_not == null and filter_owner_not_in == null and
        filter_name_contains == null and filter_name_contains_nocase == null and
        filter_name_not_contains == null and
        filter_name_starts_with == null and filter_name_starts_with_nocase == null and
        filter_name_ends_with == null and filter_name_ends_with_nocase == null and
        no_label_filters and
        filter_resolved_address == null and filter_resolver == null and
        filter_has_subdomains == null and
        filter_subdomain_count_gt == null and filter_subdomain_count_lt == null and
        filter_expiry_gt == null and filter_expiry_gte == null and
        filter_expiry_lt == null and filter_expiry_lte == null and
        filter_expiry_date_gt == null and filter_expiry_date_gte == null and
        filter_expiry_date_lt == null and filter_expiry_date_lte == null and
        filter_migrated == null and
        parsed.and_filters == null and parsed.or_filters == null;

    if (only_name_filter) {
        const exact_name = filter_name.?;
        const nh = try namehash(allocator, exact_name);

        var found_name = try database.getNameByNamehash(nh);
        if (found_name) |*name| {
            // Apply reachability filter: by default, hide unreachable rows
            // even on direct namehash lookup. Audit clients pass
            // `includeUnreachable: true` to override.
            if (!include_unreachable and !name.is_reachable) {
                defer name.deinit(database.allocator);
                return .{ .json = try allocator.dupe(u8, "[]") };
            }
            // Normalization filter — mirror getFilteredNames so this fast-path matches
            // the listing contract (domainConnection / domains both default-hide
            // non-normalized names). An explicit isNormalized wins; otherwise hide
            // non-normalized unless includeUnnormalized. (Singular domain(id:) does NOT
            // apply this — exact id/namehash lookups still return non-normalized names.)
            const norm_ok = if (parsed.is_normalized) |want|
                (name.is_normalized == want)
            else
                (include_unnormalized or name.is_normalized);
            if (!norm_ok) {
                defer name.deinit(database.allocator);
                return .{ .json = try allocator.dupe(u8, "[]") };
            }
            defer name.deinit(database.allocator);

            // A one-row page still owns nested lists (subdomains, events,
            // resolver records): prime them like any list page.
            prefetchResolverRecords(database, allocator, ctx.loaders, @as(*[1]models.Name, name), field.selections);
            const name_json = try builders.buildDomainJson(name, field.selections, .{
                .database = database,
                .depth = 0,
                .allocator = allocator,
                .loaders = ctx.loaders,
                .resolve = null, // list context: live resolution is single-name only (resolveDomain), never per-row
            });
            defer allocator.free(name_json);

            // Wrap in array: [{...}]
            var result = try allocator.alloc(u8, name_json.len + 2);
            result[0] = '[';
            @memcpy(result[1..][0..name_json.len], name_json);
            result[name_json.len + 1] = ']';
            return .{ .json = result };
        }

        // No match found - return empty array
        return .{ .json = try allocator.dupe(u8, "[]") };
    }

    // Check if any filters are set
    const has_filters = parsed.token_id != null or parsed.canonical_id != null or parsed.registry != null or
        filter_name != null or filter_name_in != null or
        filter_name_not != null or filter_name_not_in != null or
        filter_name_contains != null or filter_name_contains_nocase != null or
        filter_name_not_contains != null or
        filter_name_starts_with != null or filter_name_starts_with_nocase != null or
        filter_name_ends_with != null or filter_name_ends_with_nocase != null or
        !no_label_filters or
        filter_owner != null or filter_owner_in != null or
        filter_owner_not != null or filter_owner_not_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_expiry_date_gt != null or filter_expiry_date_gte != null or
        filter_expiry_date_lt != null or filter_expiry_date_lte != null or
        filter_migrated != null or include_unreachable or
        include_unnormalized or parsed.is_normalized != null or
        parsed.and_filters != null or parsed.or_filters != null;

    // All filters pushed to DB - no need to over-fetch
    const fetch_limit: u32 = first;

    // Map GraphQL orderBy to SQL sort field
    const sort_field = mapDomainOrderBy(order_by);
    const order_dir = order_dir_parsed;

    // Use filtered query with all filters pushed to DB
    const names = if (has_filters)
        try database.getFilteredNames(.{
            .token_id = if (parsed.token_id) |v| try normalizeU256Id(allocator, v) else null,
            .canonical_id = if (parsed.canonical_id) |v| try normalizeU256Id(allocator, v) else null,
            .registry = parsed.registry,
            .owner = filter_owner,
            .owner_in = filter_owner_in,
            .owner_not = filter_owner_not,
            .owner_not_in = filter_owner_not_in,
            .name = filter_name,
            .name_in = filter_name_in,
            .name_not = filter_name_not,
            .name_not_in = filter_name_not_in,
            .name_contains = filter_name_contains,
            .name_contains_nocase = filter_name_contains_nocase,
            .name_not_contains = filter_name_not_contains,
            .name_starts_with = filter_name_starts_with,
            .name_starts_with_nocase = filter_name_starts_with_nocase,
            .name_ends_with = filter_name_ends_with,
            .name_ends_with_nocase = filter_name_ends_with_nocase,
            .label_name = filter_label_name,
            .label_name_not = filter_label_name_not,
            .label_name_in = filter_label_name_in,
            .label_name_not_in = filter_label_name_not_in,
            .label_name_contains = filter_label_name_contains,
            .label_name_contains_nocase = filter_label_name_contains_nocase,
            .label_name_not_contains = filter_label_name_not_contains,
            .label_name_starts_with = filter_label_name_starts_with,
            .label_name_starts_with_nocase = filter_label_name_starts_with_nocase,
            .label_name_ends_with = filter_label_name_ends_with,
            .label_name_ends_with_nocase = filter_label_name_ends_with_nocase,
            .expiry_gt = filter_expiry_gt,
            .expiry_gte = filter_expiry_gte,
            .expiry_lt = filter_expiry_lt,
            .expiry_lte = filter_expiry_lte,
            .expiry_date_gt = filter_expiry_date_gt,
            .expiry_date_gte = filter_expiry_date_gte,
            .expiry_date_lt = filter_expiry_date_lt,
            .expiry_date_lte = filter_expiry_date_lte,
            .resolved_address = filter_resolved_address,
            .resolver = filter_resolver,
            .migrated = filter_migrated,
            .has_subdomains = filter_has_subdomains,
            .subdomain_count_gt = filter_subdomain_count_gt,
            .subdomain_count_lt = filter_subdomain_count_lt,
            .include_unreachable = include_unreachable,
            .include_unnormalized = include_unnormalized,
            .is_normalized = parsed.is_normalized,
            .and_group = try mapFilterGroup(parsed.and_filters, allocator),
            .or_group = try mapFilterGroup(parsed.or_filters, allocator),
        }, @intCast(skip), fetch_limit, order_dir, sort_field)
    else
        try database.getAllNamesWithOrder(null, @intCast(skip), fetch_limit, order_dir, sort_field);
    defer {
        for (names) |*name| {
            name.deinit(database.allocator);
        }
        database.allocator.free(names);
    }

    // Build JSON from DB-sorted names. Pre-size to avoid realloc churn across a
    // full page (each node is a few hundred bytes).
    var json: std.ArrayList(u8) = .empty;
    errdefer json.deinit(allocator);

    const items_to_return = @min(first, names.len);
    prefetchResolverRecords(database, allocator, ctx.loaders, names[0..@as(usize, @intCast(items_to_return))], field.selections);
    try json.ensureTotalCapacity(allocator, @as(usize, @intCast(items_to_return)) * 512 + 2);
    try json.appendSlice(allocator, "[");

    for (names[0..@as(usize, @intCast(items_to_return))], 0..) |*name, i| {
        if (i > 0) try json.appendSlice(allocator, ",");

        const name_json = try builders.buildDomainJson(name, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
            .resolve = null, // list context: live resolution is single-name only (resolveDomain), never per-row
        });
        defer allocator.free(name_json);
        try json.appendSlice(allocator, name_json);
    }
    try json.appendSlice(allocator, "]");

    return parser.FieldResult{ .json = try json.toOwnedSlice(allocator) };
}

/// Stable one-char discriminator for the sort field, embedded in keyset cursors so a
/// cursor minted under one orderBy is rejected (treated as start) if the client changes
/// orderBy mid-pagination.
fn sortFieldChar(f: db.NameSortField) u8 {
    return switch (f) {
        .created_at => 'c',
        .name => 'n',
        .expiry => 'e',
        .expiry_effective => 'x',
        .registered_at => 'r',
    };
}

/// Resolver for domainConnection query (cursor-based pagination)
pub fn resolveDomainConnection(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Parse pagination arguments
    const first = parser.getIntArg(field, "first", null);
    const after = parser.getStringArg(field, "after", null);
    const last = parser.getIntArg(field, "last", null);
    const before = parser.getStringArg(field, "before", null);

    const params = try pagination.PaginationParams.parse(
        first,
        after,
        last,
        before,
        100, // default limit
        1000, // max limit
    );

    // Parse `where` filter via the shared helper.
    var parsed = try parseDomainWhere(field, allocator);
    defer parsed.deinit(allocator);
    const filter_owner = parsed.owner;
    const filter_owner_in = parsed.owner_in;
    const filter_owner_not = parsed.owner_not;
    const filter_owner_not_in = parsed.owner_not_in;
    const filter_name = parsed.name;
    const filter_name_in = parsed.name_in;
    const filter_name_not = parsed.name_not;
    const filter_name_not_in = parsed.name_not_in;
    const filter_name_contains = parsed.name_contains;
    const filter_name_contains_nocase = parsed.name_contains_nocase;
    const filter_name_not_contains = parsed.name_not_contains;
    const filter_name_starts_with = parsed.name_starts_with;
    const filter_name_starts_with_nocase = parsed.name_starts_with_nocase;
    const filter_name_ends_with = parsed.name_ends_with;
    const filter_name_ends_with_nocase = parsed.name_ends_with_nocase;
    const filter_label_name = parsed.label_name;
    const filter_label_name_not = parsed.label_name_not;
    const filter_label_name_in = parsed.label_name_in;
    const filter_label_name_not_in = parsed.label_name_not_in;
    const filter_label_name_contains = parsed.label_name_contains;
    const filter_label_name_contains_nocase = parsed.label_name_contains_nocase;
    const filter_label_name_not_contains = parsed.label_name_not_contains;
    const filter_label_name_starts_with = parsed.label_name_starts_with;
    const filter_label_name_starts_with_nocase = parsed.label_name_starts_with_nocase;
    const filter_label_name_ends_with = parsed.label_name_ends_with;
    const filter_label_name_ends_with_nocase = parsed.label_name_ends_with_nocase;
    const filter_resolved_address = parsed.resolved_address;
    const filter_resolver = parsed.resolver;
    const filter_has_subdomains = parsed.has_subdomains;
    const filter_subdomain_count_gt = parsed.subdomain_count_gt;
    const filter_subdomain_count_lt = parsed.subdomain_count_lt;
    const filter_expiry_gt = parsed.expiry_gt;
    const filter_expiry_gte = parsed.expiry_gte;
    const filter_expiry_lt = parsed.expiry_lt;
    const filter_expiry_lte = parsed.expiry_lte;
    const filter_expiry_date_gt = parsed.expiry_date_gt;
    const filter_expiry_date_gte = parsed.expiry_date_gte;
    const filter_expiry_date_lt = parsed.expiry_date_lt;
    const filter_expiry_date_lte = parsed.expiry_date_lte;
    const filter_migrated = parsed.migrated;

    const include_unreachable = parsed.include_unreachable orelse false;
    const include_unnormalized = parsed.include_unnormalized orelse false;

    const name_filters = db.NameFilters{
        .token_id = if (parsed.token_id) |v| try normalizeU256Id(allocator, v) else null,
        .canonical_id = if (parsed.canonical_id) |v| try normalizeU256Id(allocator, v) else null,
        .registry = parsed.registry,
        .owner = filter_owner,
        .owner_in = filter_owner_in,
        .owner_not = filter_owner_not,
        .owner_not_in = filter_owner_not_in,
        .name = filter_name,
        .name_in = filter_name_in,
        .name_not = filter_name_not,
        .name_not_in = filter_name_not_in,
        .name_contains = filter_name_contains,
        .name_contains_nocase = filter_name_contains_nocase,
        .name_not_contains = filter_name_not_contains,
        .name_starts_with = filter_name_starts_with,
        .name_starts_with_nocase = filter_name_starts_with_nocase,
        .name_ends_with = filter_name_ends_with,
        .name_ends_with_nocase = filter_name_ends_with_nocase,
        .label_name = filter_label_name,
        .label_name_not = filter_label_name_not,
        .label_name_in = filter_label_name_in,
        .label_name_not_in = filter_label_name_not_in,
        .label_name_contains = filter_label_name_contains,
        .label_name_contains_nocase = filter_label_name_contains_nocase,
        .label_name_not_contains = filter_label_name_not_contains,
        .label_name_starts_with = filter_label_name_starts_with,
        .label_name_starts_with_nocase = filter_label_name_starts_with_nocase,
        .label_name_ends_with = filter_label_name_ends_with,
        .label_name_ends_with_nocase = filter_label_name_ends_with_nocase,
        .expiry_gt = filter_expiry_gt,
        .expiry_gte = filter_expiry_gte,
        .expiry_lt = filter_expiry_lt,
        .expiry_lte = filter_expiry_lte,
        .expiry_date_gt = filter_expiry_date_gt,
        .expiry_date_gte = filter_expiry_date_gte,
        .expiry_date_lt = filter_expiry_date_lt,
        .expiry_date_lte = filter_expiry_date_lte,
        .resolved_address = filter_resolved_address,
        .resolver = filter_resolver,
        .migrated = filter_migrated,
        .has_subdomains = filter_has_subdomains,
        .subdomain_count_gt = filter_subdomain_count_gt,
        .subdomain_count_lt = filter_subdomain_count_lt,
        .include_unreachable = include_unreachable,
        .include_unnormalized = include_unnormalized,
        .is_normalized = parsed.is_normalized,
        .and_group = try mapFilterGroup(parsed.and_filters, allocator),
        .or_group = try mapFilterGroup(parsed.or_filters, allocator),
    };

    const has_filters = parsed.token_id != null or parsed.canonical_id != null or parsed.registry != null or
        filter_name != null or filter_name_in != null or
        filter_name_not != null or filter_name_not_in != null or
        filter_name_contains != null or filter_name_contains_nocase != null or
        filter_name_not_contains != null or
        filter_name_starts_with != null or filter_name_starts_with_nocase != null or
        filter_name_ends_with != null or filter_name_ends_with_nocase != null or
        filter_label_name != null or filter_label_name_not != null or
        filter_label_name_in != null or filter_label_name_not_in != null or
        filter_label_name_contains != null or filter_label_name_contains_nocase != null or
        filter_label_name_not_contains != null or
        filter_label_name_starts_with != null or filter_label_name_starts_with_nocase != null or
        filter_label_name_ends_with != null or filter_label_name_ends_with_nocase != null or
        filter_owner != null or filter_owner_in != null or
        filter_owner_not != null or filter_owner_not_in != null or
        filter_resolved_address != null or filter_resolver != null or filter_has_subdomains != null or
        filter_subdomain_count_gt != null or filter_subdomain_count_lt != null or
        filter_expiry_gt != null or filter_expiry_gte != null or
        filter_expiry_lt != null or filter_expiry_lte != null or
        filter_expiry_date_gt != null or filter_expiry_date_gte != null or
        filter_expiry_date_lt != null or filter_expiry_date_lte != null or
        filter_migrated != null or include_unreachable or
        include_unnormalized or parsed.is_normalized != null or
        parsed.and_filters != null or parsed.or_filters != null;
    _ = has_filters; // keyset path always uses getFilteredNamesKeyset (handles empty filters)

    // Check which top-level fields are requested
    var wants_edges = false;
    var wants_page_info = false;
    var wants_total_count = false;
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) wants_edges = true;
        if (std.mem.eql(u8, sel.name, "pageInfo")) wants_page_info = true;
        if (std.mem.eql(u8, sel.name, "totalCount")) wants_total_count = true;
    }

    // Fast path: only totalCount requested — skip row fetching entirely
    if (wants_total_count and !wants_edges and !wants_page_info) {
        const count = try database.getFilteredNameCount(name_filters);
        const result = try std.fmt.allocPrint(allocator, "{{\"totalCount\":{d}}}", .{count});
        return parser.FieldResult{ .json = result };
    }

    // Extract node selections from query: domainConnection { edges { node { ... } } }
    var node_selections: []const parser.Field = &[_]parser.Field{};
    for (field.selections) |*sel| {
        if (std.mem.eql(u8, sel.name, "edges")) {
            for (sel.selections) |*edge_sel| {
                if (std.mem.eql(u8, edge_sel.name, "node")) {
                    node_selections = edge_sel.selections;
                    break;
                }
            }
            break;
        }
    }

    const order_by = parser.getStringArg(field, "orderBy", null);
    const sort_field = mapDomainOrderBy(order_by);

    // Default order: desc (newest first) when no orderDirection specified
    const base_dir = common.parseOrderDirection(field, db.OrderDir, .desc);

    // Keyset (seek) pagination: fetch limit+1 to detect a trailing page. Replaces
    // the former OFFSET + per-page countRowsBeforeNamehash full-table scan with an
    // index range scan anchored on the last row's (sort_value, namehash).
    const fetch_limit = params.limit + 1;

    // Combine pagination direction with user-requested order (backward inverts).
    const order_dir: db.OrderDir = if (params.direction == .backward)
        (if (base_dir == .desc) .asc else .desc)
    else
        base_dir;

    // Fingerprint the active filters + order direction; a cursor is a valid anchor only
    // for a request that reproduces it (same sort field AND same filters).
    const filter_hash = hashFilters(name_filters, base_dir);

    // Decode the cursor into a keyset anchor. A changed sort field, a changed `where`
    // filter set, or an old non-keyset cursor is treated as "start from the beginning" —
    // which also drops the stale totalCount snapshot (its reuse is gated on the anchor).
    var anchor: ?db.KeysetAnchor = null;
    var anchor_decoded: ?pagination.CursorCodec.Keyset = null;
    defer if (anchor_decoded) |d| d.deinit(allocator);
    if (params.cursor) |c| {
        if (pagination.CursorCodec.decodeKeyset(allocator, c)) |ks| {
            if (ks.field == sortFieldChar(sort_field) and ks.filter_hash == filter_hash) {
                anchor_decoded = ks;
                anchor = .{ .sort_value = ks.sort_value, .namehash = ks.namehash };
            } else {
                ks.deinit(allocator);
            }
        } else |_| {}
    }

    // Read the page rows and (for page 1) the fresh totalCount in ONE read-only snapshot,
    // so totalCount can't disagree with the rows because a write landed between the two
    // reads. Deeper pages reuse the cursor's totalCount snapshot and skip the count.
    const need_fresh_count = wants_total_count and (anchor_decoded == null or anchor_decoded.?.total_count == null);
    var snapshot_count: ?usize = null;
    var snap_tx = try db.Tx.begin(database, .read_snapshot);
    errdefer snap_tx.deinit();
    var result = try database.getFilteredNamesKeyset(name_filters, anchor, @intCast(fetch_limit), order_dir, sort_field);
    if (need_fresh_count) {
        snapshot_count = database.getFilteredNameCount(name_filters) catch |e| {
            result.deinit(database.allocator);
            return e;
        };
    }
    snap_tx.commit() catch |e| {
        result.deinit(database.allocator);
        return e;
    };
    defer result.deinit(database.allocator);
    const names = result.names;
    const sort_values = result.sort_values;

    const has_more = names.len > params.limit;
    const actual_items = @min(names.len, params.limit);

    // Backward pagination: reverse rows AND their parallel sort values together to
    // restore the user-facing (base) order.
    if (params.direction == .backward and actual_items > 1) {
        std.mem.reverse(models.Name, names[0..actual_items]);
        std.mem.reverse([]u8, sort_values[0..actual_items]);
    }

    // Batch-prefetch resolver records for this page (same N+1 fix as resolveDomains).
    prefetchResolverRecords(database, allocator, ctx.loaders, names[0..actual_items], node_selections);

    // Per-edge cursors: base64 keyset of (sort_field discriminator, row sort value, namehash).
    // totalCount is a snapshot taken once (page 1) and carried forward in the cursor,
    // so deep pagination doesn't re-run a COUNT(*) per page. Reuse the incoming
    // cursor's snapshot when present; otherwise compute once. Only when selected.
    const total_count: ?usize = if (wants_total_count) blk: {
        if (anchor_decoded) |d| {
            if (d.total_count) |tc| break :blk tc;
        }
        break :blk snapshot_count orelse try database.getFilteredNameCount(name_filters);
    } else null;

    const edge_cursors = try allocator.alloc([]const u8, actual_items);
    defer {
        for (edge_cursors) |ec| allocator.free(ec);
        allocator.free(edge_cursors);
    }
    for (0..actual_items) |i| {
        const nh_hex = try names[i].namehash.toHex(allocator);
        defer allocator.free(nh_hex);
        edge_cursors[i] = try pagination.CursorCodec.encodeKeyset(allocator, sortFieldChar(sort_field), filter_hash, total_count, sort_values[i], nh_hex);
    }

    const has_next = if (params.direction == .forward) has_more else (params.cursor != null);
    const has_prev = if (params.direction == .backward) has_more else (params.cursor != null);

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"pageInfo\":{\"hasNextPage\":");
    try json.appendSlice(allocator, if (has_next) "true" else "false");
    try json.appendSlice(allocator, ",\"hasPreviousPage\":");
    try json.appendSlice(allocator, if (has_prev) "true" else "false");
    if (actual_items > 0) {
        try json.appendSlice(allocator, ",\"startCursor\":\"");
        try json.appendSlice(allocator, edge_cursors[0]);
        try json.appendSlice(allocator, "\",\"endCursor\":\"");
        try json.appendSlice(allocator, edge_cursors[actual_items - 1]);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, ",\"startCursor\":null,\"endCursor\":null");
    }
    try json.appendSlice(allocator, "},\"edges\":[");

    for (0..actual_items) |i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "{\"cursor\":\"");
        try json.appendSlice(allocator, edge_cursors[i]);
        try json.appendSlice(allocator, "\",\"node\":");
        const domain_json = try builders.buildDomainJson(&names[i], node_selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = ctx.loaders,
            .resolve = null, // list context: live resolution is single-name only (resolveDomain), never per-row
        });
        defer allocator.free(domain_json);
        try json.appendSlice(allocator, domain_json);
        try json.appendSlice(allocator, "}");
    }
    try json.appendSlice(allocator, "]");

    if (total_count) |count| {
        const count_str = try std.fmt.allocPrint(allocator, ",\"totalCount\":{d}", .{count});
        defer allocator.free(count_str);
        try json.appendSlice(allocator, count_str);
    }
    try json.appendSlice(allocator, "}");

    return parser.FieldResult{ .json = try json.toOwnedSlice(allocator) };
}

pub fn resolveDomain(ctx: parser.ExecutionContext, field: *const parser.Field) !parser.FieldResult {
    const database: *db.Database = @ptrCast(@alignCast(ctx.database));
    const allocator = ctx.allocator;

    // Extract id argument
    const id = parser.getStringArg(field, "id", null) orelse {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    };

    // Get name from database — id may be either a name or a namehash hex string
    const nh = try resolveDomainId(allocator, id);

    // atBlock: single-entity time travel from the event log (V2 only). Lenient like the
    // rest of the query surface: an out-of-range block or a name with no V2 event history
    // (incl. V1 names) resolves to null rather than erroring.
    if (parser.getIntArg(field, "atBlock", null)) |ab_raw| {
        if (ab_raw <= 0) return parser.FieldResult{ .json = try allocator.dupe(u8, "null") };
        const ab_block: u64 = @intCast(ab_raw);
        const v2_head = (database.getSyncState(.v2) catch null) orelse 0;
        if (ab_block > v2_head) return parser.FieldResult{ .json = try allocator.dupe(u8, "null") };

        var st = try at_block_mod.reconstructV2AtBlock(database, allocator, nh, ab_block);
        defer st.deinit();
        const hist = if (st.name) |*n| n else return parser.FieldResult{ .json = try allocator.dupe(u8, "null") };

        const name_json = try builders.buildDomainJson(hist, field.selections, .{
            .database = database,
            .depth = 0,
            .allocator = allocator,
            .loaders = null, // batch caches hold CURRENT records — never mix with history
            .resolve = null, // live resolution answers "now", not "at block N"
            .at_block = @ptrCast(&st),
        });
        return parser.FieldResult{ .json = name_json };
    }
    const name_opt = try database.getNameByNamehash(nh);
    if (name_opt == null) {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    }
    var name = name_opt.?;
    defer name.deinit(database.allocator);

    // Hide unreachable domains from default lookup. There's currently no
    // `includeUnreachable` arg on the singular `domain(id:)` query; clients
    // that need orphan visibility should use `domains(where:{includeUnreachable:true})`.
    if (!name.is_reachable) {
        const null_json = try allocator.dupe(u8, "null");
        return parser.FieldResult{ .json = null_json };
    }

    // A single domain still owns nested lists (subdomains, events, resolver
    // records): prime them like any list page so they batch instead of
    // querying per row.
    prefetchResolverRecords(database, allocator, ctx.loaders, @as(*[1]models.Name, &name), field.selections);

    // Build JSON object using nested builder
    const name_json = try builders.buildDomainJson(&name, field.selections, .{
        .database = database,
        .depth = 0,
        .allocator = allocator,
        .loaders = ctx.loaders,
        .resolve = ctx.resolve,
    });
    return parser.FieldResult{ .json = name_json };
}

/// Fingerprint the active filter set + order direction for the keyset cursor. A cursor is
/// only a valid anchor for a request that reproduces this fingerprint; reusing one against
/// a changed `where`/orderDirection falls through to a fresh page (correct seek + a fresh
/// totalCount). Hashed generically so every NameFilters field, present and future, is
/// covered — a new filter can never silently escape the fingerprint.
fn hashFilters(name_filters: db.NameFilters, base_dir: db.OrderDir) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&h, name_filters, .DeepRecursive);
    std.hash.autoHash(&h, base_dir);
    return h.final();
}

test "hashFilters distinguishes filter sets and order direction" {
    const empty = db.NameFilters{};
    const by_owner = db.NameFilters{ .owner = @import("../../types/address.zig").Address.zero };
    const by_name = db.NameFilters{ .name = "alice.eth" };
    // Identical inputs hash identically; different filters/direction differ.
    try std.testing.expectEqual(hashFilters(empty, .desc), hashFilters(db.NameFilters{}, .desc));
    try std.testing.expect(hashFilters(empty, .desc) != hashFilters(by_owner, .desc));
    try std.testing.expect(hashFilters(empty, .desc) != hashFilters(by_name, .desc));
    try std.testing.expect(hashFilters(by_owner, .desc) != hashFilters(by_name, .desc));
    try std.testing.expect(hashFilters(empty, .desc) != hashFilters(empty, .asc));
    try std.testing.expect(hashFilters(db.NameFilters{ .name = "a.eth" }, .desc) != hashFilters(db.NameFilters{ .name = "b.eth" }, .desc));
}
