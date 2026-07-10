//! Unified admin/internal-endpoint authentication.
//!
//! One place decides whether a privileged request is authorized, instead of each
//! route hand-rolling its own credential check. Replaces the previous
//! `checkWebhookAuth`, which (a) compared credentials with short-circuiting
//! `std.mem.eql` (a byte-by-byte timing oracle) and (b) FAILED OPEN when no
//! password was configured — returning "authorized" for every request. This
//! module fails CLOSED (no credential configured -> `configured()` is false ->
//! callers reject) and compares in constant time.

const std = @import("std");
const zsys = @import("../utils/system.zig");

pub const AdminAuth = struct {
    basic_username: ?[]const u8,
    basic_password: ?[]const u8,
    bearer_token: ?[]const u8,
    /// Per-process random HMAC key; see `ctEqual`. Never leaves the process, so a
    /// fresh value each start is fine and strictly better than a fixed key.
    process_key: [32]u8,

    pub fn init(basic_username: ?[]const u8, basic_password: ?[]const u8, bearer_token: ?[]const u8) AdminAuth {
        var key: [32]u8 = undefined;
        zsys.randomBytes(&key);
        return .{
            .basic_username = basic_username,
            .basic_password = basic_password,
            .bearer_token = bearer_token,
            .process_key = key,
        };
    }

    /// True iff at least one full credential is configured. A protected route with
    /// no credential configured must be treated as unauthorized (fail-closed).
    pub fn configured(self: *const AdminAuth) bool {
        return (self.basic_username != null and self.basic_password != null) or self.bearer_token != null;
    }

    /// Constant-time credential comparison. `std.crypto.timing_safe.eql` only
    /// accepts fixed-length arrays, so HMAC both sides under the per-process key
    /// and compare the 32-byte digests: this hides both the content-timing (no
    /// byte-by-byte early exit) and the length of the secret.
    fn ctEqual(self: *const AdminAuth, a: []const u8, b: []const u8) bool {
        var ha: [32]u8 = undefined;
        var hb: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&ha, a, &self.process_key);
        std.crypto.auth.hmac.sha2.HmacSha256.create(&hb, b, &self.process_key);
        return std.crypto.timing_safe.eql([32]u8, ha, hb);
    }

    /// Validate the `Authorization` header of a raw HTTP request. Returns true only
    /// when a configured credential matches; false (reject) when nothing is
    /// configured, the header is absent, or the credential is wrong.
    pub fn checkRequest(self: *const AdminAuth, request: []const u8) bool {
        if (!self.configured()) return false;
        const auth_value = findAuthHeader(request) orelse return false;

        if (self.bearer_token) |tok| {
            if (std.ascii.startsWithIgnoreCase(auth_value, "bearer ")) {
                const provided = std.mem.trim(u8, auth_value["bearer ".len..], " \t");
                if (self.ctEqual(provided, tok)) return true;
            }
        }
        if (self.basic_username != null and self.basic_password != null) {
            if (std.ascii.startsWithIgnoreCase(auth_value, "basic ")) {
                const encoded = std.mem.trim(u8, auth_value["basic ".len..], " \t");
                var buf: [512]u8 = undefined;
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(encoded) catch return false;
                if (n > buf.len) return false;
                dec.decode(buf[0..n], encoded) catch return false;
                const creds = buf[0..n];
                const colon = std.mem.indexOfScalar(u8, creds, ':') orelse return false;
                // Compute both comparisons before combining so a mismatch in the
                // username doesn't short-circuit the password check's timing.
                const user_ok = self.ctEqual(creds[0..colon], self.basic_username.?);
                const pass_ok = self.ctEqual(creds[colon + 1 ..], self.basic_password.?);
                if (user_ok and pass_ok) return true;
            }
        }
        return false;
    }
};

fn findAuthHeader(request: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, request, '\n');
    while (lines.next()) |line0| {
        const line = std.mem.trimEnd(u8, line0, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;

// Precomputed "GET / HTTP/1.1\r\nAuthorization: Basic <base64(user:pass)>\r\n\r\n".
const HDR_ADMIN_S3CRET = "GET / HTTP/1.1\r\nAuthorization: Basic YWRtaW46czNjcmV0\r\n\r\n"; // admin:s3cret
const HDR_ADMIN_WRONG = "GET / HTTP/1.1\r\nAuthorization: Basic YWRtaW46d3Jvbmc=\r\n\r\n"; // admin:wrong
const HDR_EVIL_S3CRET = "GET / HTTP/1.1\r\nAuthorization: Basic ZXZpbDpzM2NyZXQ=\r\n\r\n"; // evil:s3cret

test "fails closed when no credential is configured" {
    const a = AdminAuth.init(null, null, null);
    try testing.expect(!a.configured());
    try testing.expect(!a.checkRequest(HDR_ADMIN_S3CRET));
}

test "basic auth: correct credentials accepted, wrong rejected" {
    const a = AdminAuth.init("admin", "s3cret", null);
    try testing.expect(a.configured());
    try testing.expect(a.checkRequest(HDR_ADMIN_S3CRET));
    try testing.expect(!a.checkRequest(HDR_ADMIN_WRONG));
    try testing.expect(!a.checkRequest(HDR_EVIL_S3CRET));
    try testing.expect(!a.checkRequest("GET / HTTP/1.1\r\nHost: x\r\n\r\n")); // no header
}

test "bearer token: correct accepted, wrong rejected" {
    const a = AdminAuth.init(null, null, "tok_abc123");
    try testing.expect(a.configured());
    try testing.expect(a.checkRequest("POST / HTTP/1.1\r\nAuthorization: Bearer tok_abc123\r\n\r\n"));
    try testing.expect(!a.checkRequest("POST / HTTP/1.1\r\nAuthorization: Bearer tok_wrong\r\n\r\n"));
}
