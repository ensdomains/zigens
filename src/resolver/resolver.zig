const std = @import("std");
const models = @import("../types/models.zig");
const db = @import("../storage/database.zig");
const rpc = @import("../rpc/client.zig");
const config = @import("../config.zig");
const Hash = @import("../types/hash.zig").Hash;
const Address = @import("../types/address.zig").Address;
const namehash = @import("../types/hash.zig").namehash;

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    database: *db.Database,
    client: *rpc.Client,
    config: config.Config,

    pub fn init(
        allocator: std.mem.Allocator,
        database: *db.Database,
        client: *rpc.Client,
        cfg: config.Config,
    ) Resolver {
        return .{
            .allocator = allocator,
            .database = database,
            .client = client,
            .config = cfg,
        };
    }

    pub fn resolve(self: *Resolver, name: []const u8) !?ResolverInfo {
        const nh = try namehash(self.allocator, name);

        if (try self.resolveFromDatabase(name, nh)) |info| {
            return info;
        }

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

        var labels = .{};
        defer labels.deinit(self.allocator);

        var it = std.mem.splitScalar(u8, name, '.');
        while (it.next()) |label| {
            try labels.insert(0, label);
        }

        if (labels.items.len == 0) {
            return null;
        }

        return try self.findResolverRecursive(labels.items, .v2, self.config.v2_contracts.root_registry);
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

        const resolver = try self.callGetResolver(registry, label);
        const subregistry = try self.callGetSubregistry(registry, label);

        var result: ?ResolverInfo = null;
        if (!subregistry.isZero()) {
            result = try self.findResolverRecursive(rest, chain, subregistry);
        }

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

    fn callGetResolver(self: *Resolver, registry: Address, label: []const u8) !Address {
        const sig = "getResolver(string)";
        const call_data = try self.encodeStringCall(sig, label);
        defer self.allocator.free(call_data);

        const response = try self.client.call(registry, call_data, null);
        defer self.allocator.free(response);

        if (response.len < 32) {
            return Address.zero;
        }

        return try @import("../indexer/abi.zig").ABI.decodeAddress(response, 0);
    }

    fn callGetSubregistry(self: *Resolver, registry: Address, label: []const u8) !Address {
        const sig = "getSubregistry(string)";
        const call_data = try self.encodeStringCall(sig, label);
        defer self.allocator.free(call_data);

        const response = try self.client.call(registry, call_data, null);
        defer self.allocator.free(response);

        if (response.len < 32) {
            return Address.zero;
        }

        return try @import("../indexer/abi.zig").ABI.decodeAddress(response, 0);
    }

    fn encodeStringCall(self: *Resolver, signature: []const u8, str_param: []const u8) ![]u8 {
        const sig_hash = try @import("../types/hash.zig").keccak256(self.allocator, signature);

        const str_len_padded = ((str_param.len + 31) / 32) * 32;
        const total_size = 4 + 32 + 32 + str_len_padded;

        var call_data = try self.allocator.alloc(u8, total_size);
        @memset(call_data, 0);

        @memcpy(call_data[0..4], sig_hash.bytes[0..4]);

        call_data[31] = 32;

        var len_bytes: [32]u8 = [_]u8{0} ** 32;
        var len = str_param.len;
        var i: usize = 31;
        while (len > 0) : (i -= 1) {
            len_bytes[i] = @intCast(len & 0xff);
            len >>= 8;
            if (i == 0) break;
        }
        @memcpy(call_data[32..64], &len_bytes);

        @memcpy(call_data[64 .. 64 + str_param.len], str_param);

        return call_data;
    }

    pub fn getOwner(self: *Resolver, name: []const u8) !?Address {
        const nh = try namehash(self.allocator, name);

        const name_record = try self.database.getNameByNamehash(nh) orelse return null;
        defer name_record.deinit(self.allocator);

        if (name_record.owner.isZero()) {
            return null;
        }

        return name_record.owner;
    }

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
    const std_test = @import("std");
    const contracts = @import("../contracts.zig");
    var gpa = std_test.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var database = try db.Database.init(allocator, ":memory:");
    defer database.deinit();

    var client = try rpc.Client.init(allocator, "http://localhost:8545");
    defer client.deinit();

    const test_contracts = contracts.ContractAddresses{
        .temporary_registrar = Address.zero,
        .ens_registry = Address.zero,
        .base_registrar = Address.zero,
        .eth_registrar_controller = Address.zero,
        .public_resolver = Address.zero,
        .reverse_registrar = Address.zero,
        .name_wrapper = Address.zero,
        .root_registry = Address.zero,
        .eth_registry = Address.zero,
        .registry_datastore = Address.zero,
        .eth_reverse_registrar = Address.zero,
        .l2_eth_registry = Address.zero,
        .l2_eth_registrar = Address.zero,
        .l2_registry_datastore = Address.zero,
        .l1_bridge_controller = Address.zero,
        .l2_bridge_controller = Address.zero,
        .v1_deployment_block = 0,
        .l1_deployment_block = 0,
        .l2_deployment_block = 0,
    };

    const cfg = config.Config{
        .allocator = allocator,
        .rpc_url = "http://localhost:8545",
        .database_path = ":memory:",
        .network = .sepolia,
        .start_block = 0,
        .end_block = null,
        .poll_interval = 12,
        .batch_size = 1000,
        .max_blocks_per_request = 1000,
        .rate_limit_per_second = 10,
        .api_port = 8080,
        .api_enabled = true,
        .status_port = null,
        .webhooks_enabled = false,
        .webhook_max_retries = 3,
        .max_memory_mb = 512,
        .checkpoint_interval = 100,
        .graphql_max_depth = 10,
        .graphql_max_cost = 1000,
        .metrics_enabled = false,
        .v1_contracts = test_contracts,
        .v2_contracts = test_contracts,
    };

    const resolver = Resolver.init(allocator, &database, client, cfg);
    _ = resolver;
}
