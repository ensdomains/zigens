// Test entry point for events.zig tests
// This file is located in src/ to have access to all modules
const std = @import("std");

// Import the storage module which has proper access to types
const database = @import("storage/database.zig");

// Re-export Database for tests
pub const Database = database.Database;

// The actual tests are in events.zig
// They will be discovered through the database module's imports
test {
    // Reference the events module to ensure its tests are run
    _ = @import("storage/events.zig");
}
