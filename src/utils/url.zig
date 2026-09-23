const std = @import("std");

/// Maximum allowed URL length
pub const MAX_URL_LENGTH: usize = 2048;

/// Validates a webhook URL for security using industry-standard std.Uri (RFC 3986)
/// Checks:
/// - Length limits
/// - Valid HTTP/HTTPS protocol only
/// - Not targeting localhost/private IPs (basic SSRF protection)
/// - No dangerous characters
pub fn validateWebhookUrl(url: []const u8) !void {
    // Check length
    if (url.len == 0) {
        return error.UrlEmpty;
    }
    if (url.len > MAX_URL_LENGTH) {
        return error.UrlTooLong;
    }

    // SECURITY: Use built-in std.Uri for RFC 3986 compliant parsing (industry standard)
    const uri = std.Uri.parse(url) catch {
        return error.InvalidUrlFormat;
    };

    // Validate scheme is HTTP or HTTPS only
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return error.InvalidUrlProtocol;
    }

    // Extract hostname using std.Uri's built-in host extraction
    var hostname_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = uri.getHost(&hostname_buf) catch {
        return error.InvalidUrlFormat;
    };
    const hostname = host_name.bytes;

    // Block localhost, loopback, private, link-local, and cloud-metadata ranges (SSRF protection).
    // IPv4:
    //   127.0.0.0/8       — loopback
    //   10.0.0.0/8        — RFC1918 private
    //   172.16.0.0/12     — RFC1918 private (172.16–172.31)
    //   192.168.0.0/16    — RFC1918 private
    //   169.254.0.0/16    — link-local (AWS/GCP/Azure metadata lives at 169.254.169.254)
    //   100.64.0.0/10     — CGNAT (100.64–100.127)
    //   0.0.0.0/8         — "this network" / default route
    // IPv6:
    //   ::1               — loopback
    //   fc00::/7          — unique local addresses (fc00–fdff)
    //   fe80::/10         — link-local (fe80–febf)
    if (std.mem.eql(u8, hostname, "localhost") or
        std.mem.startsWith(u8, hostname, "127.") or
        std.mem.startsWith(u8, hostname, "10.") or
        std.mem.startsWith(u8, hostname, "192.168.") or
        std.mem.startsWith(u8, hostname, "169.254.") or
        isInCgnatRange(hostname) or
        std.mem.startsWith(u8, hostname, "0.") or
        isInRfc1918_172(hostname) or
        std.mem.eql(u8, hostname, "[::1]") or
        std.mem.eql(u8, hostname, "::1") or
        isInIpv6UlaRange(hostname) or
        isInIpv6LinkLocalRange(hostname))
    {
        return error.PrivateIpNotAllowed;
    }

    // Check for null bytes and control characters in URL
    for (url) |byte| {
        if (byte == 0x00) {
            return error.NullByteInUrl;
        }
        // Control characters (except tab) are not allowed in URLs
        if (byte < 0x20 and byte != 0x09) {
            return error.ControlCharacterInUrl;
        }
    }
}

/// 172.16.0.0/12 covers 172.16.0.0 – 172.31.255.255. Second octet must be 16–31.
fn isInRfc1918_172(hostname: []const u8) bool {
    if (!std.mem.startsWith(u8, hostname, "172.")) return false;
    const rest = hostname[4..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
    return second >= 16 and second <= 31;
}

/// 100.64.0.0/10 covers 100.64.0.0 – 100.127.255.255. Second octet must be 64–127.
fn isInCgnatRange(hostname: []const u8) bool {
    if (!std.mem.startsWith(u8, hostname, "100.")) return false;
    const rest = hostname[4..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
    const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;
    return second >= 64 and second <= 127;
}

/// IPv6 Unique Local Address fc00::/7 — prefix fc* or fd* (case-insensitive).
/// Literal in URLs is bracketed, e.g. [fc00::1].
fn isInIpv6UlaRange(hostname: []const u8) bool {
    const inner = stripIpv6Brackets(hostname);
    if (inner.len < 2) return false;
    const c0 = std.ascii.toLower(inner[0]);
    const c1 = std.ascii.toLower(inner[1]);
    if (c0 != 'f') return false;
    return c1 == 'c' or c1 == 'd';
}

/// IPv6 Link-Local fe80::/10 — prefix starts with fe80, fe90, fea0, feb0.
fn isInIpv6LinkLocalRange(hostname: []const u8) bool {
    const inner = stripIpv6Brackets(hostname);
    if (inner.len < 4) return false;
    if (std.ascii.toLower(inner[0]) != 'f' or std.ascii.toLower(inner[1]) != 'e') return false;
    // Third char must be 8, 9, a, or b (binary prefix 1111 1110 10)
    const c2 = std.ascii.toLower(inner[2]);
    return c2 == '8' or c2 == '9' or c2 == 'a' or c2 == 'b';
}

fn stripIpv6Brackets(hostname: []const u8) []const u8 {
    if (hostname.len >= 2 and hostname[0] == '[' and hostname[hostname.len - 1] == ']') {
        return hostname[1 .. hostname.len - 1];
    }
    return hostname;
}

test "validateWebhookUrl accepts valid HTTPS URLs" {
    try validateWebhookUrl("https://example.com/webhook");
    try validateWebhookUrl("https://api.example.com:8080/webhook");
    try validateWebhookUrl("https://example.com/webhook?token=abc123");
}

test "validateWebhookUrl accepts valid HTTP URLs" {
    try validateWebhookUrl("http://example.com/webhook");
}

test "validateWebhookUrl rejects empty URL" {
    try std.testing.expectError(error.UrlEmpty, validateWebhookUrl(""));
}

test "validateWebhookUrl rejects URL too long" {
    const long_url = "https://example.com/" ++ "x" ** 3000;
    try std.testing.expectError(error.UrlTooLong, validateWebhookUrl(long_url));
}

test "validateWebhookUrl rejects invalid protocols" {
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("ftp://example.com"));
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("file:///etc/passwd"));
    try std.testing.expectError(error.InvalidUrlProtocol, validateWebhookUrl("javascript:alert(1)"));
}

test "validateWebhookUrl rejects localhost" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://localhost/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://127.0.0.1/webhook"));
}

test "validateWebhookUrl rejects private IPs" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://192.168.1.1/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://10.0.0.1/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://172.16.0.1/webhook"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://172.31.255.255/webhook"));
}

test "validateWebhookUrl rejects link-local (cloud metadata)" {
    // AWS / GCP / Azure metadata lives at 169.254.169.254 — must be blocked.
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://169.254.169.254/metadata"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://169.254.0.1/"));
}

test "validateWebhookUrl rejects CGNAT range" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://100.64.0.1/"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://100.127.255.255/"));
}

test "validateWebhookUrl rejects 0.0.0.0 / 127.x.x.x" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://0.0.0.0/"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://127.0.0.2/"));
}

test "validateWebhookUrl rejects IPv6 ULA and link-local" {
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://[fc00::1]/"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://[fd12:3456:789a::1]/"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://[fe80::1]/"));
    try std.testing.expectError(error.PrivateIpNotAllowed, validateWebhookUrl("http://[feb0::1]/"));
}

test "validateWebhookUrl does NOT reject public 172.x outside 172.16–31" {
    // 172.15 and 172.32 are public (not part of 172.16.0.0/12).
    try validateWebhookUrl("http://172.15.0.1/webhook");
    try validateWebhookUrl("http://172.32.0.1/webhook");
}

test "validateWebhookUrl does NOT reject 100.x outside CGNAT 64–127" {
    try validateWebhookUrl("http://100.63.0.1/webhook");
    try validateWebhookUrl("http://100.128.0.1/webhook");
}

test "validateWebhookUrl rejects null bytes" {
    const url_with_null = "http://example.com\x00/webhook";
    try std.testing.expectError(error.NullByteInUrl, validateWebhookUrl(url_with_null));
}

test "validateWebhookUrl rejects control characters" {
    const url_with_control = "http://example.com\x01/webhook";
    try std.testing.expectError(error.ControlCharacterInUrl, validateWebhookUrl(url_with_control));
}
