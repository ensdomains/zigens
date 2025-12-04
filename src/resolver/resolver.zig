const std = @import("std");
const models = @import("../types/models.zig");
const db = @import("../storage/database.zig");
const rpc = @import("../rpc/client.zig");
const config = @import("../config.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const namehash = @import("../types/hash.zig").namehash;

/// ENSv2 Hierarchical Resolver
/// Implements the resolution process as described in the ENSv2 design doc
pub const Resolver = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    l1_client: *rpc.Client,
    l2_client: *rpc.Client,
    config: config.Config,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db.Database,
        l1_client: *rpc.Client,
        l2_client: *rpc.Client,
        cfg: config.Config,
    ) Resolver {
        return .{
            .allocator = allocator,
            .database = database,
            .l1_client = l1_client,
            .l2_client = l2_client,
            .config = cfg,
        };
    }

    /// Resolve a name to its resolver address
    /// Implements the hierarchical resolution algorithm from ENSv2 design
    pub fn resolve(self: *Resolver, name: []const u8) !?ResolverInfo {
        const nh = try namehash(self.allocator, name);

        // First, try to resolve from database (cached)
        if (try self.resolveFromDatabase(name, nh)) |info| {
            return info;
        }

        // If not in database, resolve on-chain
        return try self.resolveOnChain(name, nh);
    }

    fn resolveFromDatabase(self: *Resolver, name: []const u8, nh: Hash) !?ResolverInfo {
        _ = name;

        const name_record = try self.database.getNameByNamehash(nh) orelse return null;
        defer name_record.deinit(self.allocator);

        if (name_record.resolver.isZero()) {
            return null;
        }

        return ResolverInfo{
            .resolver = name_record.resolver,
            .chain = name_record.chain,
        };
    }

    fn resolveOnChain(self: *Resolver, name: []const u8, nh: Hash) !?ResolverInfo {
        _ = nh;

        // Split name into labels
        var labels = .{};
        defer labels.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, name, '.');
        while (it.next()) |label| {
            try labels.insert(0, label); // Reverse order for traversal
        }

        if (labels.items.len == 0) {
            return null;
        }

        // Start from root and traverse down
        // The ENSv2 resolution algorithm:
        // 1. Start at root registry
        // 2. For each label, call getSubregistry() and getResolver()
        // 3. Return the first non-zero resolver found (closest to target)

        return try self.findResolverRecursive(labels.items, .l2, self.config.l2_root_registry);
    }

    fn findResolverRecursive(
        self: *Resolver,
        labels: []const []const u8,
        chain: models.Chain,
        registry: Address,
    ) !?ResolverInfo {
        if (labels.len == 0) {
            return null;
        }

        const label = labels[0];
        const rest = labels[1..];

        // Call getResolver(label) on current registry
        const resolver = try self.callGetResolver(chain, registry, label);

        // Call getSubregistry(label) on current registry
        const subregistry = try self.callGetSubregistry(chain, registry, label);

        // Recursively resolve the rest
        var result: ?ResolverInfo = null;
        if (!subregistry.isZero()) {
            result = try self.findResolverRecursive(rest, chain, subregistry);
        }

        // Return resolver || recursive_result (first non-null)
        if (result) |r| {
            return r;
        } else if (!resolver.isZero()) {
            return ResolverInfo{
                .resolver = resolver,
                .chain = chain,
            };
        }

        return null;
    }

    fn callGetResolver(self: *Resolver, chain: models.Chain, registry: Address, label: []const u8) !Address {
        const client = if (chain == .l1) self.l1_client else self.l2_client;

        // Encode call: getResolver(string)
        const sig = "getResolver(string)";
        var call_data = try self.encodeStringCall(sig, label);
        defer self.allocator.free(call_data);

        const response = try client.call(registry, call_data, null);
        defer self.allocator.free(response);

        if (response.len < 32) {
            return Address.zero;
        }

        return try @import("../indexer/abi.zig").ABI.decodeAddress(response, 0);
    }

    fn callGetSubregistry(self: *Resolver, chain: models.Chain, registry: Address, label: []const u8) !Address {
        const client = if (chain == .l1) self.l1_client else self.l2_client;

        // Encode call: getSubregistry(string)
        const sig = "getSubregistry(string)";
        var call_data = try self.encodeStringCall(sig, label);
        defer self.allocator.free(call_data);

        const response = try client.call(registry, call_data, null);
        defer self.allocator.free(response);

        if (response.len < 32) {
            return Address.zero;
        }

        return try @import("../indexer/abi.zig").ABI.decodeAddress(response, 0);
    }

    fn encodeStringCall(self: *Resolver, signature: []const u8, str_param: []const u8) ![]u8 {
        // Get function selector (first 4 bytes of keccak256(signature))
        const sig_hash = try @import("../types/hash.zig").keccak256(self.allocator, signature);

        // Calculate total size: 4 (selector) + 32 (offset) + 32 (length) + padded string
        const str_len_padded = ((str_param.len + 31) / 32) * 32;
        const total_size = 4 + 32 + 32 + str_len_padded;

        var call_data = try self.allocator.alloc(u8, total_size);
        @memset(call_data, 0);

        // Function selector
        @memcpy(call_data[0..4], sig_hash.bytes[0..4]);

        // Offset to string data (always 32 for single string param)
        call_data[31] = 32;

        // String length
        var len_bytes: [32]u8 = [_]u8{0} ** 32;
        var len = str_param.len;
        var i: usize = 31;
        while (len > 0) : (i -= 1) {
            len_bytes[i] = @intCast(len & 0xff);
            len >>= 8;
            if (i == 0) break;
        }
        @memcpy(call_data[32..64], &len_bytes);

        // String data
        @memcpy(call_data[64 .. 64 + str_param.len], str_param);

        return call_data;
    }

    /// Get owner of a name
    pub fn getOwner(self: *Resolver, name: []const u8) !?Address {
        const nh = try namehash(self.allocator, name);

        const name_record = try self.database.getNameByNamehash(nh) orelse return null;
        defer name_record.deinit(self.allocator);

        if (name_record.owner.isZero()) {
            return null;
        }

        return name_record.owner;
    }

    /// Check if a name exists
    pub fn exists(self: *Resolver, name: []const u8) !bool {
        const nh = try namehash(self.allocator, name);
        const name_record = try self.database.getNameByNamehash(nh);

        if (name_record) |n| {
            defer n.deinit(self.allocator);
            return true;
        }

        return false;
    }
};

pub const ResolverInfo = struct {
    resolver: Address,
    chain: models.Chain,
};

test "Resolver init" {
    const std = @import("std");
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    var l1_client = try rpc.Client.init(allocator, "http://localhost:8545");
    defer l1_client.deinit();

    var l2_client = try rpc.Client.init(allocator, "http://localhost:8546");
    defer l2_client.deinit();

    const cfg = config.Config{
        .l1_rpc_url = "http://localhost:8545",
        .l2_rpc_url = "http://localhost:8546",
        .l1_root_registry = Address.zero,
        .l2_root_registry = Address.zero,
        .l1_eth_registry = Address.zero,
        .l2_eth_registry = Address.zero,
        .l1_datastore = Address.zero,
        .l2_datastore = Address.zero,
        .l1_universal_resolver = Address.zero,
        .l1_fallback_resolver = Address.zero,
        .l1_migration_contract = Address.zero,
        .l2_migration_contract = Address.zero,
        .l1_ejection_controller = Address.zero,
        .l2_ejection_controller = Address.zero,
        .l1_start_block = 0,
        .l2_start_block = 0,
        .l1_confirmations = 12,
        .l2_confirmations = 2,
        .poll_interval = 12,
        .database_path = ":memory:",
        .api_port = 8080,
        .webhooks_enabled = false,
        .webhook_max_retries = 3,
        .log_level = "info",
    };

    const resolver = Resolver.init(allocator, &database, l1_client, l2_client, cfg);
    _ = resolver;
}
