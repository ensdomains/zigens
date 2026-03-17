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

// ============================================================================
// HISTORICAL BLOCK NUMBERS (Mainnet)
// ============================================================================

/// Historical block numbers for Ethereum mainnet
/// These mark important ENS deployment and migration milestones
pub const MainnetBlocks = struct {
    /// Temporary Registrar deployment - May 2017
    /// Start of ENS auction system (pre-V1)
    pub const temp_registrar_start: u64 = 3327417;

    /// V1 Permanent Registrar deployment - May 2019
    /// End of auction system, start of instant registration
    pub const v1_migration: u64 = 9380410;

    /// Name Wrapper deployment - September 2022
    pub const name_wrapper_deployment: u64 = 15628465;
};

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Convert timing constants to nanoseconds for std.Thread.sleep
pub fn toNanoseconds(ms: u64) u64 {
    return ms * std.time.ns_per_ms;
}

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

test "mainnet blocks are in order" {
    const testing = std.testing;

    try testing.expect(MainnetBlocks.temp_registrar_start < MainnetBlocks.v1_migration);
    try testing.expect(MainnetBlocks.v1_migration < MainnetBlocks.name_wrapper_deployment);
}
