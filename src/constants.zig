/// Centralized constants for the ENS indexer
/// This module contains all magic numbers, timing values, and well-known hashes
/// that were previously scattered throughout the codebase.
const Hash = @import("types/hash.zig").Hash;

// ============================================================================
// TIMING CONSTANTS
// ============================================================================

/// Timing constants for delays, retries, and intervals
pub const Timing = struct {
    /// Delay between RPC batch calls to avoid rate limiting (milliseconds)
    pub const rpc_batch_delay_ms: u64 = 50;

    /// Delay before retrying a failed RPC call (milliseconds)
    pub const rpc_retry_delay_ms: u64 = 50;

    /// Delay after non-network errors before retry (milliseconds)
    pub const error_recovery_delay_ms: u64 = 5000;

    /// Network health check interval (milliseconds)
    pub const network_check_interval_ms: u64 = 3000;
};

// ============================================================================
// PAGINATION CONSTANTS
// ============================================================================

/// Pagination defaults for queries
pub const Pagination = struct {
    /// Default number of results per page
    pub const default_limit: u32 = 100;

    /// Maximum allowed results per page
    pub const max_limit: u32 = 1000;
};

// ============================================================================
// RPC BATCHING CONSTANTS
// ============================================================================

/// RPC batching limits for multi-address queries
pub const RpcBatching = struct {
    /// Number of contract addresses per eth_getLogs call
    pub const addresses_per_call: u32 = 60;

    /// Minimum block chunk size for adaptive chunking
    pub const min_chunk_size: u64 = 100;

    /// Maximum block chunk size for adaptive chunking
    pub const max_chunk_size: u64 = 10000;

    /// Absolute minimum chunk size (never go below this)
    pub const absolute_min_chunk: u64 = 10;
};

// ============================================================================
// SQLITE CONSTANTS
// ============================================================================

/// SQLite configuration values
pub const SQLite = struct {
    /// Busy timeout in milliseconds (wait for locks)
    pub const busy_timeout_ms: u32 = 5000;

    /// Cache size in KB (negative means KB, positive means pages)
    /// 100MB = 100000 KB
    pub const cache_size_kb: i32 = -100000;

    /// Journal size limit in bytes (512MB)
    pub const journal_size_limit: i64 = 512 * 1024 * 1024;

    /// Default number of read-only connections in the API's connection pool.
    /// Each pooled connection is its own `sqlite3*` + prepared-statement cache,
    /// so a request thread can run queries without sharing a connection with
    /// any other thread (sharing a single connection across the thread-per-
    /// connection server is unsafe — `SQLITE_CONFIG_SERIALIZED` only guards
    /// individual C calls, not a prepare→step→finalize sequence). WAL mode lets
    /// these connections read concurrently. Overridable via API_DB_POOL_SIZE.
    pub const db_pool_size: u32 = 16;

    /// Hard cap on the pool size, including overflow connections opened when the
    /// pool is exhausted. Bounds memory (each connection has its own page cache)
    /// and file-descriptor usage under load.
    pub const db_pool_max: u32 = 64;
};

// ============================================================================
// VALIDATION CONSTANTS
// ============================================================================

/// Validation limits
pub const Validation = struct {
    /// Maximum GraphQL query length in bytes
    pub const max_graphql_query_length: usize = 10000;

    /// Maximum array length for ABI decoding
    pub const max_abi_array_length: usize = 10000;
};

// ============================================================================
// WELL-KNOWN ENS VALUES
// ============================================================================

/// Well-known ENS namehashes and nodes
pub const WellKnown = struct {
    /// Namehash of "eth" - the .eth TLD
    /// keccak256(keccak256(0x0) + keccak256("eth"))
    pub const eth_namehash: Hash = Hash.fromHex("93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae") catch unreachable;

    /// Namehash of "addr.reverse" - reverse resolution root
    pub const reverse_namehash: Hash = Hash.fromHex("91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2") catch unreachable;

    /// Empty/root namehash (0x0)
    pub const root_namehash: Hash = Hash.fromHex("0000000000000000000000000000000000000000000000000000000000000000") catch unreachable;
};

const std = @import("std");

// ============================================================================
// TESTS
// ============================================================================

test "well-known hashes are valid" {
    const testing = std.testing;

    // ETH namehash should be 32 bytes
    try testing.expectEqual(@as(usize, 32), WellKnown.eth_namehash.bytes.len);
    try testing.expectEqual(@as(usize, 32), WellKnown.reverse_namehash.bytes.len);
    try testing.expectEqual(@as(usize, 32), WellKnown.root_namehash.bytes.len);
}
