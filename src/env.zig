const std = @import("std");

/// Simple .env file parser
pub fn loadEnv(allocator: std.mem.Allocator, path: []const u8) !std.StringHashMap([]const u8) {
    var env_map = std.StringHashMap([]const u8).init(allocator);
    errdefer {
        var it = env_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        env_map.deinit();
    }

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.warn("No .env file found at {s}, using defaults", .{path});
            return env_map;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Find = separator
        const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;

        const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);

        if (key.len == 0) continue;

        // Store key and value as owned strings
        const key_owned = try allocator.dupe(u8, key);
        errdefer allocator.free(key_owned);

        const value_owned = try allocator.dupe(u8, value);
        errdefer allocator.free(value_owned);

        try env_map.put(key_owned, value_owned);
    }

    return env_map;
}

/// Get environment variable with fallback to .env map
pub fn getEnv(env_map: *const std.StringHashMap([]const u8), key: []const u8, default: []const u8) []const u8 {
    // First check actual environment
    if (std.process.getEnvVarOwned(env_map.allocator, key)) |value| {
        return value;
    } else |_| {
        // Fall back to .env file
        if (env_map.get(key)) |value| {
            return value;
        }
    }
    return default;
}

/// Get integer from environment
pub fn getEnvInt(env_map: *const std.StringHashMap([]const u8), comptime T: type, key: []const u8, default: T) T {
    const value = getEnv(env_map, key, "");
    if (value.len == 0) return default;

    return std.fmt.parseInt(T, value, 10) catch default;
}

/// Get boolean from environment
pub fn getEnvBool(env_map: *const std.StringHashMap([]const u8), key: []const u8, default: bool) bool {
    const value = getEnv(env_map, key, "");
    if (value.len == 0) return default;

    if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "yes")) {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "0") or std.ascii.eqlIgnoreCase(value, "no")) {
        return false;
    }
    return default;
}

pub fn deinitEnv(env_map: *std.StringHashMap([]const u8)) void {
    var it = env_map.iterator();
    while (it.next()) |entry| {
        env_map.allocator.free(entry.key_ptr.*);
        env_map.allocator.free(entry.value_ptr.*);
    }
    env_map.deinit();
}
