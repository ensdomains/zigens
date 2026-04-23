/// Common imports for ENS GraphQL resolvers
pub const db = @import("../../storage/database.zig");
pub const models = @import("../../types/models.zig");
pub const Hash = @import("../../types/hash.zig").Hash;
pub const Address = @import("../../types/address.zig").Address;
pub const namehash_fn = @import("../../types/hash.zig").namehash;
pub const json_utils = @import("../../utils/json.zig");

// Import generic GraphQL library
pub const parser = @import("../../lib/graphql/parser.zig");
pub const pagination = @import("../../lib/graphql/pagination.zig");

// Import ENS-specific modules.
// Note: `builders` is NOT re-exported here — that would create a cycle with
// builders/builders.zig. Files needing the builder layer (or `builders.NestedContext`)
// should import `../builders/builders.zig` directly.
pub const loaders = @import("../loaders.zig");

// Re-export shared helpers/constants from the neutral api/common.zig so resolver
// files can access them via the same `common.*` namespace.
const api_common = @import("../common.zig");
pub const Pagination = api_common.Pagination;
pub const parsePagination = api_common.parsePagination;
pub const parseOrderDirection = api_common.parseOrderDirection;
pub const MAX_FIRST = api_common.MAX_FIRST;
pub const DEFAULT_SKIP = api_common.DEFAULT_SKIP;
pub const getObjectArg = api_common.getObjectArg;
pub const matchStringArg = api_common.matchStringArg;
pub const matchIntArg = api_common.matchIntArg;
pub const matchBoolArg = api_common.matchBoolArg;
pub const matchAddressArg = api_common.matchAddressArg;
